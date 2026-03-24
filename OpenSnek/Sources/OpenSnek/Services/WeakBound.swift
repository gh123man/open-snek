import Foundation

@propertyWrapper
struct WeakBound<Value: AnyObject> {
    private weak var storage: Value?
    private let ownerType: String
    private let dependencyLabel: String

    init(_ ownerType: String, dependency dependencyLabel: String) {
        self.ownerType = ownerType
        self.dependencyLabel = dependencyLabel
    }

    var wrappedValue: Value {
        guard let storage else {
            preconditionFailure("\(ownerType) accessed before \(dependencyLabel) was bound")
        }
        return storage
    }

    var optionalValue: Value? {
        storage
    }

    mutating func bind(_ value: Value) {
        storage = value
    }
}
