# Renders assets/demo.gif:  vhs assets/demo.tape
# Runs against a throwaway HOME (/tmp/h) with stubbed brew/npx/claude/codex,
# so nothing on the real machine is touched. Build it first: assets/demo-env.sh
Output assets/demo.gif
Set Shell "bash"
Set FontSize 14
Set Width 1000
Set Height 600
Set Padding 20
Set Framerate 12
Set PlaybackSpeed 1.6
Set Theme "Catppuccin Mocha"
Set TypingSpeed 50ms
Hide
Type "source /tmp/h/run.sh" Enter
Sleep 500ms
Show
Type "ai-env-setup" Sleep 500ms Enter
Sleep 3s
Type "x" Down Type "x" Sleep 700ms Enter
Sleep 7s
Ctrl+A Sleep 600ms Enter Sleep 2s
Ctrl+A Sleep 600ms Enter Sleep 2s
Ctrl+A Sleep 600ms Enter
Sleep 22s
Type "clear" Enter
Type "# later: re-run it - picks are remembered, synced work is skipped" Enter
Type "ai-env-setup" Sleep 500ms Enter
Sleep 3s
Enter Sleep 6s
Enter Sleep 2s
Enter Sleep 2s
Enter Sleep 12s
