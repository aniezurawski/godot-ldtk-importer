The import context suite requires gdUnit4 at `res://addons/gdUnit4`.

Run it in a separate Godot project containing this addon's directory and
`gdunit4/ImportContextTest.gd`, with no LDtk source files. The lifecycle cases
override the import body with a stub; they never import LDtk data.

The eight lifecycle cases require an editor-mode gdUnit4 runner because Godot
only allows `EditorImportPlugin` instances in the editor. They are automatically
skipped by a runtime runner. The remaining eighteen cases work in either mode.

The runtime command is:

```sh
godot --headless --path <validation-project> --script addons/gdUnit4/bin/GdUnitCmdTool.gd --ignoreHeadlessMode -a res://gdunit4/ImportContextTest.gd
```
