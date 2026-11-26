// Temporary interface-contract stub for feat/system-auth.
// Matches the contract agreed with feat/face-model (Sources/Matching.swift).
// Delete this file when merging feat/face-model so Matching.swift's real implementation takes over.
import Combine
import Foundation

enum AuthResult: String, Codable {
    case success, failure, spoof, noFace, notEnrolled, busy, cameraUnavailable
}

private var activeAuthWatch: AnyCancellable?
private var activeAuthTimer: DispatchWorkItem?

extension Engine {
    /// Displays `reason` in the notch and runs one face scan, invoking `completion` on the main thread.
    func authenticate(reason: String, timeout: TimeInterval, completion: @escaping (AuthResult) -> Void) {
        DispatchQueue.main.async {
            if self.ui.phase == .scanning || self.ui.phase == .enrolling {
                completion(.busy)
                return
            }
            guard self.isEnrolled else {
                self.show(.notice, "얼굴 미등록")
                completion(.notEnrolled)
                return
            }

            var finished = false
            func finishOnce(_ result: AuthResult) {
                guard !finished else { return }
                finished = true
                activeAuthWatch?.cancel()
                activeAuthWatch = nil
                activeAuthTimer?.cancel()
                activeAuthTimer = nil
                completion(result)
            }

            let timer = DispatchWorkItem { finishOnce(.failure) }
            activeAuthTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + max(timeout, 1), execute: timer)

            self.start(.scanning)
            self.ui.text = reason

            activeAuthWatch = self.ui.$phase
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { phase in
                    switch phase {
                    case .success:
                        finishOnce(.success)
                    case .fail:
                        finishOnce(.failure)
                    case .notice:
                        finishOnce(.cameraUnavailable)
                    case .idle:
                        finishOnce(.failure)
                    case .scanning, .enrolling:
                        break
                    }
                }
        }
    }
}
