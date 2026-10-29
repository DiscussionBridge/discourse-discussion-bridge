# Private URL-domain dependency

The receiver uses a privately namespaced UTS46 dependency and Unicode 17.0.0
normalization data. It does not change Core's `URI`, `String`, native Unicode
tables, global gems or hosting requirements. This is not an operator option.
Only UTS46 ToASCII is the receiver's supported dependency interface; the bundled
upstream IDNA2008/WHATWG convenience methods are not a product API.

Normal installation and packaging use the committed bundle. They do not fetch
Unicode files, rebuild data, run these tools or require a newer Ruby version.
The bundle manifest records every member's byte size/hash, data inputs, upstream
commits and explicit owned changes. MIT, Ruby BSD and Unicode licenses ship with
the runtime files.

## Explicit dependency refresh

Use a clean `uri-idna` checkout at
`29fadb2b73599c66db3202d62ceb1d25eefeca12` (0.3.1). Stage the official Unicode
17 files named/pinned in `vendor.rb` under a directory ending in `17.0.0`.
The UCD files come from `https://www.unicode.org/Public/17.0.0/ucd/`;
`DerivedJoiningType.txt` is under its `extracted/` subdirectory. The IDNA mapping
comes from `https://www.unicode.org/Public/17.0.0/idna/`. Retain Unicode's license.

Stage Ruby source files as `lib_unicode_normalize_normalize.rb`,
`template_unicode_norm_gen.tmpl`, and `BSDL` in each source directory. The older
engine commit is `0581089df9f0af0fe6b64cb8167987c211100947`; the maintained
composition/generator correction is from
`a6c4c8e8e6ab9a280f5dd4f757785669fddb897e`. The generator verifies their exact
source/input hashes. It takes the maintained composition correction verbatim
while retaining compatible cache/block syntax, rather than requiring newer
Ruby or modifying host normalization. Input paths are explicit, not machine-
specific defaults.

```text
ruby tools/cms-idna/vendor.rb URI_IDNA_SOURCE UCD17 RUBY33_SOURCE RUBY_CURRENT_SOURCE NEW_OUTPUT
```

The output must be a new directory; nothing is deleted or overwritten by an
implicit cleanup. The refresh is offline after inputs are staged. It normalizes
dependency source/license transport to LF, generates complete joining types,
fixes upstream empty-set/ContextJ bugs, and uses pinned normalization even in
build-time codepoint-property generation. It never serializes caller URLs.

Before replacing committed members, compare two independent outputs, run the
official Unicode17 IDNA and normalization corpora on supported Ruby runtimes,
run the common URL-domain fixtures and real receiver origin/collision/replay
tests, and complete applicable exact-candidate review. A dependency corpus or
package hash alone is not receiver or installed-product acceptance.

The receiver loader pins the complete manifest SHA-256, checks its inventory and
every member before requiring any dependency source, and rejects unexpected
hidden members or symlinks. A deliberate refresh also updates that explicit
loader pin in the same reviewed source batch. Run
`ruby spec/scripts/v4_idna_loader_checks.rb` to check intact loading and refusal
of missing, changed, extra and forged-manifest packages before dependency code
can execute. These synthetic copied fixtures are temporary; the candidate bundle
is never altered by the checks.
