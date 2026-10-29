# V4 codec test vectors

These byte-exact vectors come from the DiscussionBridge adapter-contract
readiness commit `53a3356402b26cd0bb35e4d2a6c2a1af323f7424`, whose fixture files
are unchanged from its published main parent. The plugin's codec check pins their
SHA-256 values before use. They are test inputs, not runtime dependencies or
authority to publish content.

The plugin's checks must work from an ordinary standalone checkout. They do not
require a sibling contract working directory. When the approved protocol's
vectors change, update these copies and their pins together and rerun native and
value-level checks; a passing vector set is not whole-product acceptance.
