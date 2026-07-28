# Agent icon attribution

Each mark here belongs to the agent it names. Cairn draws them only to say
which agent a row is about — the marks are not Cairn's, and Cairn is not
endorsed by or affiliated with their owners.

Every file is a silhouette: the app renders it as a template image, so only the
alpha channel survives and the fill colours below never reach the screen.

## `AgentIcon-codex.svg`, `AgentIcon-claude.svg`

Copied from `ui/public/provider-icons/ProviderIcon-{codex,claude}.svg` in
[openclaw/openclaw](https://github.com/openclaw/openclaw), which in turn copied
them from `Sources/CodexBar/Resources/` in
[steipete/CodexBar](https://github.com/steipete/CodexBar) (MIT, © 2026 Peter
Steinberger). Geometry unchanged.

The OpenAI and Anthropic names and marks belong to OpenAI and Anthropic.

## `AgentIcon-openclaw.svg`

Copied from `apps/linux/src-tauri/icons/tray-template.svg` in
[openclaw/openclaw](https://github.com/openclaw/openclaw) (MIT). It is already
authored as a macOS menu bar template icon, so it is the mark OpenClaw itself
puts in a menu bar at this size. Geometry unchanged.

## Hermes

Hermes ships no vector mark — its only artwork is a raster banner that turns to
mush below about 32pt. `AgentGlyph` falls back to a lettermark for it, and for
any agent Cairn has not been taught. Replace this note if an official SVG
appears.
