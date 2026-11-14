# RblxDeltaImport

StudioLite importer for Delta: reads a `.rbxl` / `.rbxm` (binary) or an XML-format file from the executor workspace and rebuilds its instances in the running game.

## Load

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/dvaustria741-a11y/RblxDeltaImport/main/StudioLiteImport.lua"))()
```

## Use

1. Put your file in `Delta/Workspace/StudioLiteImport/` (the script creates the folder on first run).
2. Run the loader, pick the file in the list or type its name, press **Import**.
3. **Placement** button: original locations (Workspace, Lighting, ReplicatedStorage, ...) or one folder in Workspace.
4. **Run LocalScripts** executes the imported LocalScripts on the client.
5. **Copy report** copies the import report.

Re-importing the same file removes the previous import first.

## Limits

- Everything exists on your client only; the server and other players never see it.
- Script sources are written into the instance only if the executor allows it (`Source` or `setscriptsource`). Sources are always saved as `.lua` files in `StudioLiteImport/<file>_scripts/`.
- Server `Script`s cannot run on a client. LocalScripts run through `loadstring`, `setfenv` and `getfenv`.
- Unsupported property types are skipped and named in the report.
