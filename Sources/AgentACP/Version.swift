// The version `nawa --version` prints. The release workflow overwrites this
// file with the tag's version (`v0.6.0` → "0.6.0") before it builds, so
// releasing needs no version commit; every other build says "dev".
let nawaVersion = "dev"
