import Foundation
import AOATouch

do {
    try AOATouchCommand.run()
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
