# Security policy

## Reporting a vulnerability

Please report security issues privately, through GitHub's
[private vulnerability reporting](https://github.com/nseaSeb/facturx/security/advisories/new)
on this repository, rather than in a public issue.

Include what you can: the affected version, a minimal input that reproduces the
problem, and what you observed. A response should reach you within a week.

## Supported versions

The library is pre-1.0. Fixes go to the latest minor version; there are no
backports to earlier ones.

## What is worth reporting

This library parses two kinds of untrusted input, and both are in scope:

- **CII XML** — `Facturx.CII.parse/1` and `Facturx.XSD.validate/2`. XML parsing
  is done with Saxy and OTP's `:xmerl`; `<!DOCTYPE>` is rejected outright before
  validation, so external entities never resolve. A way past that is in scope.
- **PDF bytes** — `Facturx.Extract.extract/1` and `Facturx.Embed.embed/3`. Both
  work on the raw binary. An input that makes them consume unbounded memory or
  CPU, or that gets `Facturx.Embed` to produce a document whose contents were not
  supplied by the caller, is in scope.

Out of scope: sending invoice data to a **public** Saxon endpoint. That is what
`Facturx.Validate` does when you do not set `:endpoint`, it is documented, and
self-hosting is the recommended production setup.
