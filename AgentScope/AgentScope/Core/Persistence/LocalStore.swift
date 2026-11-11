import CoreData
import Foundation

public final class LocalStore: @unchecked Sendable {
    public let container: NSPersistentContainer
    private let context: NSManagedObjectContext

    public init(directoryURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let model = Self.makeModel()
        let container = NSPersistentContainer(name: "AgentScope", managedObjectModel: model)
        let storeURL = directoryURL.appending(path: "AgentScope.sqlite")
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.setOption(false as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(false as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        container.persistentStoreDescriptions = [description]

        let loadResult = StoreLoadResult()
        let semaphore = DispatchSemaphore(value: 0)
        container.loadPersistentStores { _, error in
            loadResult.error = error
            semaphore.signal()
        }
        semaphore.wait()
        if let error = loadResult.error { throw error }

        self.container = container
        self.context = container.viewContext
        self.context.automaticallyMergesChangesFromParent = false
        self.context.undoManager = nil
    }

    public func saveSnapshot(_ items: [ServiceItem], timestamp: Date = Date()) throws {
        let payload = try JSONEncoder().encode(items)
        let mutationResult = StoreMutationResult()
        context.performAndWait {
            do {
                let entity = NSEntityDescription.entity(forEntityName: "ServiceSnapshotEntity", in: context)!
                let object = NSManagedObject(entity: entity, insertInto: context)
                object.setValue(UUID().uuidString, forKey: "id")
                object.setValue(timestamp, forKey: "timestamp")
                object.setValue(payload, forKey: "payload")
                try context.save()
            } catch {
                mutationResult.error = error
            }
        }
        if let error = mutationResult.error { throw error }
    }

    public func record(_ record: OperationRecord) throws {
        let mutationResult = StoreMutationResult()
        context.performAndWait {
            do {
                let entity = NSEntityDescription.entity(forEntityName: "OperationRecordEntity", in: context)!
                let object = NSManagedObject(entity: entity, insertInto: context)
                object.setValue(record.id.uuidString, forKey: "id")
                object.setValue(record.serviceID, forKey: "serviceID")
                object.setValue(record.action.rawValue, forKey: "action")
                object.setValue(record.timestamp, forKey: "timestamp")
                object.setValue(record.succeeded, forKey: "succeeded")
                object.setValue(record.message, forKey: "message")
                object.setValue(record.backupPath, forKey: "backupPath")
                try context.save()
            } catch {
                mutationResult.error = error
            }
        }
        if let error = mutationResult.error { throw error }
    }

    public func fetchOperationRecords(serviceID: String? = nil) throws -> [OperationRecord] {
        let fetchResult = StoreFetchResult()
        context.performAndWait {
            do {
                let request = NSFetchRequest<NSManagedObject>(entityName: "OperationRecordEntity")
                if let serviceID {
                    request.predicate = NSPredicate(format: "serviceID == %@", serviceID)
                }
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
                let objects = try context.fetch(request)
                fetchResult.records = objects.compactMap { object in
                    guard let idString = object.value(forKey: "id") as? String,
                          let id = UUID(uuidString: idString),
                          let serviceID = object.value(forKey: "serviceID") as? String,
                          let actionString = object.value(forKey: "action") as? String,
                          let action = OperationAction(rawValue: actionString),
                          let timestamp = object.value(forKey: "timestamp") as? Date,
                          let succeeded = object.value(forKey: "succeeded") as? Bool,
                          let message = object.value(forKey: "message") as? String else {
                        return nil
                    }
                    return OperationRecord(
                        id: id,
                        serviceID: serviceID,
                        action: action,
                        timestamp: timestamp,
                        succeeded: succeeded,
                        message: message,
                        backupPath: object.value(forKey: "backupPath") as? String
                    )
                }
            } catch {
                fetchResult.error = error
            }
        }
        if let error = fetchResult.error { throw error }
        return fetchResult.records
    }

    public func saveLatestAnalysis(_ record: AnalysisRecord) throws {
        let payload = try JSONEncoder().encode(record)
        let mutationResult = StoreMutationResult()
        context.performAndWait {
            do {
                let request = NSFetchRequest<NSManagedObject>(entityName: "AnalysisRecordEntity")
                request.predicate = NSPredicate(format: "serviceID == %@", record.serviceID)
                for object in try context.fetch(request) {
                    context.delete(object)
                }

                let entity = NSEntityDescription.entity(forEntityName: "AnalysisRecordEntity", in: context)!
                let object = NSManagedObject(entity: entity, insertInto: context)
                object.setValue(record.id.uuidString, forKey: "id")
                object.setValue(record.serviceID, forKey: "serviceID")
                object.setValue(record.analyzedAt, forKey: "timestamp")
                object.setValue(record.model, forKey: "model")
                object.setValue(payload, forKey: "payload")
                try context.save()
            } catch {
                mutationResult.error = error
            }
        }
        if let error = mutationResult.error { throw error }
    }

    public func fetchLatestAnalysis(serviceID: String) throws -> AnalysisRecord? {
        let fetchResult = AnalysisFetchResult()
        context.performAndWait {
            do {
                let request = NSFetchRequest<NSManagedObject>(entityName: "AnalysisRecordEntity")
                request.predicate = NSPredicate(format: "serviceID == %@", serviceID)
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                request.fetchLimit = 1
                guard let object = try context.fetch(request).first,
                      let payload = object.value(forKey: "payload") as? Data else { return }
                fetchResult.record = try JSONDecoder().decode(AnalysisRecord.self, from: payload)
            } catch {
                fetchResult.error = error
            }
        }
        if let error = fetchResult.error { throw error }
        return fetchResult.record
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let snapshot = NSEntityDescription()
        snapshot.name = "ServiceSnapshotEntity"
        snapshot.managedObjectClassName = "NSManagedObject"
        snapshot.properties = [
            attribute("id", .stringAttributeType, optional: false),
            attribute("timestamp", .dateAttributeType, optional: false),
            attribute("payload", .binaryDataAttributeType, optional: false)
        ]

        let operation = NSEntityDescription()
        operation.name = "OperationRecordEntity"
        operation.managedObjectClassName = "NSManagedObject"
        operation.properties = [
            attribute("id", .stringAttributeType, optional: false),
            attribute("serviceID", .stringAttributeType, optional: false),
            attribute("action", .stringAttributeType, optional: false),
            attribute("timestamp", .dateAttributeType, optional: false),
            attribute("succeeded", .booleanAttributeType, optional: false),
            attribute("message", .stringAttributeType, optional: false),
            attribute("backupPath", .stringAttributeType, optional: true)
        ]

        let analysis = NSEntityDescription()
        analysis.name = "AnalysisRecordEntity"
        analysis.managedObjectClassName = "NSManagedObject"
        analysis.properties = [
            attribute("id", .stringAttributeType, optional: false),
            attribute("serviceID", .stringAttributeType, optional: false),
            attribute("timestamp", .dateAttributeType, optional: false),
            attribute("model", .stringAttributeType, optional: false),
            attribute("payload", .binaryDataAttributeType, optional: false)
        ]

        model.entities = [snapshot, operation, analysis]
        return model
    }

    private static func attribute(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        return attribute
    }
}

private final class StoreLoadResult: @unchecked Sendable {
    var error: Error?
}

private final class StoreMutationResult: @unchecked Sendable {
    var error: Error?
}

private final class StoreFetchResult: @unchecked Sendable {
    var records: [OperationRecord] = []
    var error: Error?
}

private final class AnalysisFetchResult: @unchecked Sendable {
    var record: AnalysisRecord?
    var error: Error?
}
