import Foundation

final class ModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var progress: [String: Double] = [:]
    @Published var errors: [String: String] = [:]
    @Published var installed: Set<String> = []

    private var tasks: [Int: String] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    override init() {
        super.init()
        refresh()
    }

    func refresh() {
        installed = Set(LocalModel.all.filter { FileManager.default.fileExists(atPath: Paths.models.appendingPathComponent($0.file).path) }.map(\.id))
    }

    func download(_ m: LocalModel) {
        guard progress[m.id] == nil else { return }
        errors[m.id] = nil
        progress[m.id] = 0
        let t = session.downloadTask(with: m.url)
        tasks[t.taskIdentifier] = m.id
        t.resume()
    }

    func delete(_ m: LocalModel) {
        try? FileManager.default.removeItem(at: Paths.models.appendingPathComponent(m.file))
        refresh()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = tasks[downloadTask.taskIdentifier], totalBytesExpectedToWrite > 0 else { return }
        progress[id] = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = tasks[downloadTask.taskIdentifier], let m = LocalModel.all.first(where: { $0.id == id }) else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { errors[id] = "Download failed (HTTP \(code))"; return }
        let dest = Paths.models.appendingPathComponent(m.file)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: location, to: dest) } catch { errors[id] = error.localizedDescription }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = tasks.removeValue(forKey: task.taskIdentifier) else { return }
        progress[id] = nil
        if let error { errors[id] = error.localizedDescription }
        refresh()
    }
}
