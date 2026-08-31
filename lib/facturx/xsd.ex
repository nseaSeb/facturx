defmodule Facturx.XSD do
  @moduledoc """
  Validate CII XML against the official EN 16931 XSD — **pure Elixir, in-process**.

  Uses OTP's `:xmerl_xsd` (no external tool, no network, no Port).

  When the `:facturx` application is running, `Facturx.XSD.Cache` compiles each
  bundled schema once and shares it via `:persistent_term`, so validation runs in
  the caller process — in parallel, ~0.6 ms/call. If the cache isn't running
  (or a cached schema's table has gone away), it falls back to compiling per call
  (~5 ms) inside a short-lived task, so the schema's ETS table is reclaimed on
  exit.

  All five profile schemas ship, under `priv/xsd/{minimum,basicwl,basic,en16931,
  extended}/` — 80 KB in total. `:extended` is the one that accepts the
  line-level French extensions `EXT-FR-FE-*`. An unknown profile returns
  `{:error, {:xsd_not_bundled, profile}}`.

  The matching schematrons ship for `:en16931` and `:extended` only: those two
  weigh 2.8 MB, and the other three would add 4 MB more. See `Facturx.Validate`,
  whose `:xsl` option takes a stylesheet of your own.

  ## Security

  Input is treated as untrusted. A `<!DOCTYPE>` is **rejected** and external
  entity/DTD fetching is disabled, so neither XXE (external entity file/URL
  reads) nor entity-expansion bombs ("billion laughs") are possible. Legitimate
  CII/Factur-X XML never carries a DTD.

  > `:xmerl_xsd` is a *partial* XSD 1.0 implementation. On the CII EN 16931
  > schema it correctly catches missing mandatory elements, wrong data types,
  > unexpected elements, wrong order and cardinality — but it is not a guarantee
  > of full XSD 1.0 conformance. Business rules live in `Facturx.Validate`
  > (Schematron).
  """

  # profile => bundled root schema (relative to priv/xsd/)
  @schemas %{
    minimum: "minimum/Factur-X_MINIMUM.xsd",
    basic_wl: "basicwl/Factur-X_BASICWL.xsd",
    basic: "basic/Factur-X_BASIC.xsd",
    en16931: "en16931/Factur-X_EN16931.xsd",
    extended: "extended/Factur-X_EXTENDED.xsd"
  }

  @typedoc "An XSD validation error — the raw `:xmerl_xsd` reason, inspected."
  @type error :: String.t()

  @doc """
  Validate `xml` against the profile's CII XSD.

  Options:

    * `:profile` — schema to use (default: detected from the XML, else `:en16931`)
  """
  @spec validate(binary(), keyword()) ::
          {:ok, :valid} | {:error, {:invalid, [error()]}} | {:error, term()}
  def validate(xml, opts \\ []) when is_binary(xml) do
    profile = opts[:profile] || Facturx.Profile.detect(xml) || :en16931

    case Map.fetch(@schemas, profile) do
      :error ->
        {:error, {:xsd_not_bundled, profile}}

      {:ok, rel} ->
        case :persistent_term.get(pt_key(profile), nil) do
          nil -> compile_and_validate(rel, xml)
          state -> fast_or_fallback(state, rel, xml)
        end
    end
  end

  # --- internals shared with Facturx.XSD.Cache ------------------------------

  @doc false
  @spec bundled() :: [{Facturx.profile(), charlist()}]
  def bundled, do: Enum.map(@schemas, fn {profile, rel} -> {profile, schema_path(rel)} end)

  @doc false
  def pt_key(profile), do: {__MODULE__, :schema, profile}

  defp schema_path(rel) do
    :facturx |> Application.app_dir(["priv", "xsd", rel]) |> String.to_charlist()
  end

  # --- validation -----------------------------------------------------------

  # Fast path: validate against the shared, pre-compiled schema in the caller
  # process. If that raises (e.g. the cache stopped and its ETS table is gone),
  # recompile per call instead of surfacing a spurious error.
  defp fast_or_fallback(state, rel, xml) do
    core_validate(state, xml)
  rescue
    _ -> compile_and_validate(rel, xml)
  catch
    _, _ -> compile_and_validate(rel, xml)
  end

  # Fallback: compile + validate in a short-lived task so the schema's ETS table
  # is reclaimed on exit (used when no usable cached schema is available).
  defp compile_and_validate(rel, xml) do
    task =
      Task.async(fn ->
        try do
          case process_schema(schema_path(rel)) do
            {:ok, state} -> core_validate(state, xml)
            err -> err
          end
        rescue
          e -> {:error, {:xsd_exception, Exception.message(e)}}
        catch
          kind, val -> {:error, {:xsd_error, kind, val}}
        end
      end)

    Task.await(task, 30_000)
  catch
    :exit, reason -> {:error, {:xsd_error, reason}}
  end

  # No rescue here on purpose: a raise means the (cached) schema table is dead,
  # which the caller uses to trigger the recompile fallback. A genuine schema
  # violation is *returned* as {:error, {:invalid, _}}, not raised.
  defp core_validate(state, xml) do
    with {:ok, doc} <- scan(xml) do
      case :xmerl_xsd.validate(doc, state) do
        {:error, reasons} -> {:error, {:invalid, format_errors(reasons)}}
        {el, _state} when is_tuple(el) and elem(el, 0) == :xmlElement -> {:ok, :valid}
        other -> {:error, {:xsd_unexpected, other}}
      end
    end
  end

  defp process_schema(path) do
    case :xmerl_xsd.process_schema(path) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, {:xsd_schema_error, reason}}
    end
  end

  # Parse untrusted XML safely: reject any DTD and disable external fetches, then
  # parse raw bytes (not codepoints) so xmerl decodes per the XML declaration.
  defp scan(xml) do
    if has_doctype?(xml) do
      {:error, :doctype_forbidden}
    else
      {doc, _rest} =
        :xmerl_scan.string(:erlang.binary_to_list(xml),
          quiet: true,
          fetch_fun: fn _uri, global_state -> {:ok, :not_fetched, global_state} end
        )

      {:ok, doc}
    end
  rescue
    _ -> {:error, :malformed_xml}
  catch
    _, _ -> {:error, :malformed_xml}
  end

  defp has_doctype?(xml), do: String.contains?(xml, "<!DOCTYPE")

  defp format_errors(reasons) when is_list(reasons), do: Enum.map(reasons, &format_error/1)
  defp format_errors(reason), do: [format_error(reason)]

  defp format_error(reason), do: reason |> inspect(limit: :infinity) |> String.slice(0, 500)
end
