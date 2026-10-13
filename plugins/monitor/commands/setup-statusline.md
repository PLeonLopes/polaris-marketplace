---
description: Set up the polaris-monitor usage status line (5-hour and weekly limits)
argument-hint: "[--force|--remove]"
---

Run this command and report its output to the user verbatim:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-statusline.sh" "${CLAUDE_PLUGIN_DATA}" $ARGUMENTS
```

Do not edit `settings.json` yourself, retry, or try to fix a failure. If the output says a status line already exists, tell the user they can run `/polaris-monitor:setup-statusline --force` to replace it. If it asks for `jq`, show the install command that fits their system.
