Place these font files here (referenced by index.html via @font-face):

  space-grotesk.woff2       (weights 400-700)
  plus-jakarta-sans.woff2   (weights 400-800)
  jetbrains-mono.woff2      (weights 400-600)

If a file is missing, the page falls back to system-ui / ui-monospace and
still renders correctly — this is not a hard dependency.
