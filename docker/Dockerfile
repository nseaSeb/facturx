# Saxon server preloaded with the EN 16931 code-list DB, for running the bundled
# Schematron locally and in CI.
#
# Two things make the stock image unusable as-is:
#
#   1. The Schematron XSLT loads its code-list DB through document(...), which
#      Saxon refuses unless started with --insecure. The stock CMD is
#      ["/bin/sh","-c","java $JAVA_OPTS -jar app.jar"], and `docker run <image>
#      --insecure` *replaces* that CMD instead of appending to it, so the
#      container dies silently. Hence the explicit CMD below.
#   2. Left to its own devices the XSLT fetches the code-list DB over the
#      network on every validation — slow, and it leaks that you are validating.
#      Baking it in keeps validation offline and pins the ruleset.
#
# Build from the repository root, so the code-list DB comes from priv/:
#
#   docker build -f docker/Dockerfile -t facturx-saxon .
#   docker run -d --rm -p 5000:5000 --name facturx-saxon facturx-saxon
#
# Then point Facturx.Validate at it, resolving the DB from the image:
#
#   Facturx.validate(xml,
#     endpoint: "http://localhost:5000/transform",
#     codedb_url: "file:///opt/facturx/FACTUR-X_EN16931_codedb.xml")
#
# Note: the upstream image is amd64-only, so this runs emulated on arm64 hosts
# (a validation then takes on the order of a minute).
FROM ghcr.io/willemvlh/saxon-server

# Third-party artefacts — see priv/NOTICE.md at the repository root. Carried into
# the image because BSD-3-Clause requires the licence text to travel with a
# redistribution, and UN/CEFACT requires its notice to accompany the schemas.
COPY priv/schematron/en16931/FACTUR-X_EN16931_codedb.xml /opt/facturx/
COPY priv/schematron/LICENSE.akretion.txt /opt/facturx/
COPY priv/NOTICE.md /opt/facturx/

# --insecure permits document() to read the file above. Everything else stays at
# the upstream default.
CMD ["/bin/sh", "-c", "java $JAVA_OPTS -jar app.jar --insecure"]
