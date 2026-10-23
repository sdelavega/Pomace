# 1.0.2 history fixture

`history-1.0.2.sqlite` was written by PomaceCore from commit
`53fdf97f30bf1fd459b34d21be80bf34ca00e890` (1.0.2), archived into a
throwaway directory with `git archive 53fdf97 | tar -x -C "$fixture_tmp"`.
No branch or checkout was switched. Only the temporary package received a
`HistoryFixture` executable target depending on `PomaceCore`.

The throwaway executable was run with `swift run HistoryFixture <output.sqlite>`:

```swift
import Foundation
import PomaceCore

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let path = "/Users/alex/Documents/Fixture"
do {
    let store = try Store(url: url)
    try store.addWatchedDirectory(path: path)
    try store.updateSchedule(path: path,
        schedule: SweepSchedule(cadence: .weekly, preferredHour: 3), mode: .maximumSavings)
    try store.recordSweep(path: path, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        duration: 2, filesCompressed: 3, bytesReclaimed: 4096)
    try store.recordSweep(path: path, startedAt: Date(timeIntervalSince1970: 1_700_000_100),
        duration: 0, deferral: .onBattery)
    try store.recordSweep(path: path, startedAt: Date(timeIntervalSince1970: 1_700_000_200),
        duration: 1, filesFailed: 1, error: "Fixture compressor error")
}
```

The Store was closed, the database checkpointed, and the SQLite file copied here;
the archive, executable, and temporary directory were deleted. No SQL inserts or
schema rewrites were used to synthesize the fixture. The fake user is `alex`.

The database contains schema version 2, one watched folder with persisted mode
`Maximum savings`, and three runs: completed, deferred with raw code `onBattery`,
and failed with a legacy plain-text error. Tests copy the fixture before opening
it so WAL files and migrations never modify these original bytes.

SHA-256: `15ec6575df51afb602f2a0a83b4f6bc3fd6d49a8d938eb8d8ad47316c4851cd1`.
