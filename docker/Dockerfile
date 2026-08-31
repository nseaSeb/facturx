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
# Pinned by digest, not by :latest. On 2026-08-11 the upstream tag moved to a
# build that answers 400 to every /transform request, turning all 15 schematron
# tests red on a change that had nothing to do with them. A validation image has
# to be reproducible or it is not evidence of anything.
#
# The tag is carried alongside the digest, and is not decoration: Dependabot
# resolves a digest by re-resolving a tag, so a digest-only FROM is one it can
# never open a PR against — the pin would go stale in exactly the silence
# .github/dependabot.yml claims to prevent. The digest is what is used; the tag
# is what makes the update visible.
#
# v1.15 is where the pin sits. Upstream also publishes a v2.x line (v2.7 at the
# time of writing) which nothing here has evaluated, and its :latest currently
# resolves to v1.17 — one more reason not to track it.
FROM ghcr.io/willemvlh/saxon-server:v1.15@sha256:c0959035f4a659584e8a846132cd34d8618bea63990ad0099f42ff6957cd108b

# Third-party artefacts — see priv/NOTICE.md at the repository root. Carried into
# the image because BSD-3-Clause requires the licence text to travel with a
# redistribution, and UN/CEFACT requires its notice to accompany the schemas.
COPY priv/schematron/minimum/FACTUR-X_MINIMUM_codedb.xml /opt/facturx/
COPY priv/schematron/basicwl/FACTUR-X_BASIC-WL_codedb.xml /opt/facturx/
COPY priv/schematron/basic/FACTUR-X_BASIC_codedb.xml /opt/facturx/
COPY priv/schematron/en16931/FACTUR-X_EN16931_codedb.xml /opt/facturx/
COPY priv/schematron/extended/FACTUR-X_EXTENDED_codedb.xml /opt/facturx/
COPY priv/schematron/LICENSE.akretion.txt /opt/facturx/
COPY priv/NOTICE.md /opt/facturx/

# --timeout is in **milliseconds**, which the help text does not say — passing
# 300 for "five minutes" gives 300 ms and times out essentially every
# transformation. Five minutes is 300000.
#
# It needs raising at all because the stock default is short enough that the
# emulated arm64 run exceeds it: compiling the 4 MB EXTENDED stylesheet under
# concurrent requests made the server abort with a TimeoutException, surfacing as
# an HTTP 400 on whichever test was unlucky.
#
# --insecure permits document() to read the file above. Everything else stays at
# the upstream default.
CMD ["/bin/sh", "-c", "java $JAVA_OPTS -jar app.jar --insecure --timeout 300000"]
