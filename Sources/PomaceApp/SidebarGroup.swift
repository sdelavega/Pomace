import Foundation

struct SidebarGroup: Identifiable {
    let isScheduled: Bool
    let paths: [String]
    var id: Bool { isScheduled }
    var title: String { isScheduled ? AppStrings.scheduled : AppStrings.notScheduled }

    static func grouped(_ paths: [String], isScheduled: (String) -> Bool) -> [SidebarGroup] {
        var scheduled: [String] = []
        var manual: [String] = []
        for path in paths {
            if isScheduled(path) { scheduled.append(path) } else { manual.append(path) }
        }
        return [SidebarGroup(isScheduled: true, paths: scheduled),
                SidebarGroup(isScheduled: false, paths: manual)].filter { !$0.paths.isEmpty }
    }

    func accessibilityLabels(scheduleSummary: (String) -> String) -> [String] {
        [title] + paths.map {
            AppStrings.accessibilityDetail(($0 as NSString).lastPathComponent, scheduleSummary($0))
        }
    }
}
