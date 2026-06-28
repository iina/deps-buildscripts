# TODO

## versions.env — unused libplacebo tarball entries

`LIBPLACEBO_URL` and `LIBPLACEBO_SHA256` in `versions.env` are no longer used.
`build-libplacebo.sh` switched to a recursive `git clone` (to get the `glad2`
submodule for OpenGL support), so the tarball URL and checksum are dead config.

Options:
- Remove both variables from `versions.env`
- Or replace them with a `LIBPLACEBO_COMMIT` pin for reproducibility
  (a tag-based clone is stable but a commit hash would be more explicit)
