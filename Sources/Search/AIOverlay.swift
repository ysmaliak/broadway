import AppKit

struct AIStage {
    var foldedTasks: Set<UUID> = []
}

extension Browser {
    func aiKey(_ event: NSEvent) -> Bool {
        drivingKey(event) || deskKey(event)
    }

    func aiState() -> [String: Any] {
        ["acting": active?.agentActing ?? ""]
    }
}
