import Contacts
import ContactsUI
import Flutter
import UIKit

@available(iOS 9.0, *)
public class SwiftContactsServicePlugin: NSObject, FlutterPlugin,
    CNContactViewControllerDelegate, CNContactPickerDelegate
{
    private var pendingResult: FlutterResult? = nil
    private var localizedLabels: Bool = true
    private weak var viewController: UIViewController?
    static let FORM_OPERATION_CANCELED: Int = 1
    static let FORM_COULD_NOT_BE_OPEN: Int = 2

    // MARK: - Registration
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "github.com/clovisnicolas/flutter_contacts",
            binaryMessenger: registrar.messenger()
        )
        let instance = SwiftContactsServicePlugin(
            viewController: registrar.viewController
        )
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance.preloadContactView()
    }

    public init(viewController: UIViewController?) {
        self.viewController = viewController
        super.init()
    }

    // MARK: - Method call handler
    public func handle(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        switch call.method {
        case "getContacts":
            DispatchQueue.global(qos: .userInitiated).async {
                let args = call.arguments as? [String: Any] ?? [:]
                let contacts = self.getContacts(
                    query: args["query"] as? String,
                    withThumbnails: args["withThumbnails"] as? Bool ?? false,
                    photoHighResolution: args["photoHighResolution"] as? Bool
                        ?? false,
                    phoneQuery: false,
                    emailQuery: false,
                    orderByGivenName: args["orderByGivenName"] as? Bool
                        ?? false,
                    localizedLabels: args["iOSLocalizedLabels"] as? Bool ?? true
                )
                DispatchQueue.main.async { result(contacts) }
            }

        case "getContactsForPhone":
            DispatchQueue.global(qos: .userInitiated).async {
                let args = call.arguments as? [String: Any] ?? [:]
                let contacts = self.getContacts(
                    query: args["phone"] as? String,
                    withThumbnails: args["withThumbnails"] as? Bool ?? false,
                    photoHighResolution: args["photoHighResolution"] as? Bool
                        ?? false,
                    phoneQuery: true,
                    emailQuery: false,
                    orderByGivenName: args["orderByGivenName"] as? Bool
                        ?? false,
                    localizedLabels: args["iOSLocalizedLabels"] as? Bool ?? true
                )
                DispatchQueue.main.async { result(contacts) }
            }

        case "getContactsForEmail":
            DispatchQueue.global(qos: .userInitiated).async {
                let args = call.arguments as? [String: Any] ?? [:]
                let contacts = self.getContacts(
                    query: args["email"] as? String,
                    withThumbnails: args["withThumbnails"] as? Bool ?? false,
                    photoHighResolution: args["photoHighResolution"] as? Bool
                        ?? false,
                    phoneQuery: false,
                    emailQuery: true,
                    orderByGivenName: args["orderByGivenName"] as? Bool
                        ?? false,
                    localizedLabels: args["iOSLocalizedLabels"] as? Bool ?? true
                )
                DispatchQueue.main.async { result(contacts) }
            }

        case "addContact":
            DispatchQueue.global(qos: .userInitiated).async {
                if let dict = call.arguments as? [String: Any] {
                    let contact = self.dictionaryToContact(dictionary: dict)
                    let errString = self.addContact(contact: contact)
                    DispatchQueue.main.async {
                        if errString.isEmpty {
                            result(nil)
                        } else {
                            result(
                                FlutterError(
                                    code: "add_failed",
                                    message: errString,
                                    details: nil
                                )
                            )
                        }
                    }
                } else {
                    result(
                        FlutterError(
                            code: "bad_args",
                            message: "Invalid arguments",
                            details: nil
                        )
                    )
                }
            }

        case "deleteContact":
            DispatchQueue.global(qos: .userInitiated).async {
                if let dict = call.arguments as? [String: Any],
                    self.deleteContact(dictionary: dict)
                {
                    DispatchQueue.main.async { result(nil) }
                } else {
                    DispatchQueue.main.async {
                        result(
                            FlutterError(
                                code: "delete_failed",
                                message:
                                    "Failed to delete contact, make sure it has a valid identifier",
                                details: nil
                            )
                        )
                    }
                }
            }

        case "updateContact":
            DispatchQueue.global(qos: .userInitiated).async {
                if let dict = call.arguments as? [String: Any],
                    self.updateContact(dictionary: dict)
                {
                    DispatchQueue.main.async { result(nil) }
                } else {
                    DispatchQueue.main.async {
                        result(
                            FlutterError(
                                code: "update_failed",
                                message:
                                    "Failed to update contact, make sure it has a valid identifier",
                                details: nil
                            )
                        )
                    }
                }
            }

        case "openContactForm":
            let args = call.arguments as? [String: Any] ?? [:]
            localizedLabels = args["iOSLocalizedLabels"] as? Bool ?? true
            self.pendingResult = result
            DispatchQueue.main.async { _ = self.openContactForm() }

        case "openExistingContact":
            let args = call.arguments as? [String: Any] ?? [:]
            localizedLabels = args["iOSLocalizedLabels"] as? Bool ?? true
            self.pendingResult = result
            if let contactDict = args["contact"] as? [String: Any] {
                DispatchQueue.main.async {
                    _ = self.openExistingContact(
                        contact: contactDict,
                        result: result
                    )
                }
            } else {
                result(
                    FlutterError(
                        code: "bad_args",
                        message: "Missing contact dictionary",
                        details: nil
                    )
                )
            }

        case "openDeviceContactPicker":
            let args = call.arguments as? [String: Any] ?? [:]
            localizedLabels = args["iOSLocalizedLabels"] as? Bool ?? true
            self.pendingResult = result
            DispatchQueue.main.async {
                self.openDeviceContactPicker(arguments: args, result: result)
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Contacts fetching
    func getContacts(
        query: String?,
        withThumbnails: Bool,
        photoHighResolution: Bool,
        phoneQuery: Bool,
        emailQuery: Bool = false,
        orderByGivenName: Bool,
        localizedLabels: Bool
    ) -> [[String: Any]] {
        var contacts: [CNContact] = []
        var result = [[String: Any]]()

        let store = CNContactStore()
        var keys: [Any] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactEmailAddressesKey,
            CNContactPhoneNumbersKey,
            CNContactFamilyNameKey,
            CNContactGivenNameKey,
            CNContactMiddleNameKey,
            CNContactNamePrefixKey,
            CNContactNameSuffixKey,
            CNContactPostalAddressesKey,
            CNContactOrganizationNameKey,
            CNContactJobTitleKey,
            CNContactBirthdayKey,
        ]

        if withThumbnails {
            if photoHighResolution {
                keys.append(CNContactImageDataKey)
            } else {
                keys.append(CNContactThumbnailImageDataKey)
            }
        }

        let fetchRequest = CNContactFetchRequest(
            keysToFetch: keys as! [CNKeyDescriptor]
        )

        if let q = query, !phoneQuery && !emailQuery {
            fetchRequest.predicate = CNContact.predicateForContacts(
                matchingName: q
            )
        }

        if #available(iOS 11, *) {
            if let q = query, phoneQuery {
                let phoneNumberPredicate = CNPhoneNumber(stringValue: q)
                fetchRequest.predicate = CNContact.predicateForContacts(
                    matching: phoneNumberPredicate
                )
            } else if let q = query, emailQuery {
                fetchRequest.predicate = CNContact.predicateForContacts(
                    matchingEmailAddress: q
                )
            }
        }

        do {
            try store.enumerateContacts(
                with: fetchRequest,
                usingBlock: { (contact, stop) in
                    if phoneQuery {
                        if #available(iOS 11, *) {
                            contacts.append(contact)
                        } else if let q = query,
                            self.has(contact: contact, phone: q)
                        {
                            contacts.append(contact)
                        }
                    } else if emailQuery {
                        if #available(iOS 11, *) {
                            contacts.append(contact)
                        } else if let q = query,
                            contact.emailAddresses.contains(where: {
                                $0.value.caseInsensitiveCompare(
                                    q as NSString as String
                                ) == .orderedSame
                            })
                        {
                            contacts.append(contact)
                        }
                    } else {
                        contacts.append(contact)
                    }
                }
            )
        } catch {
            NSLog("Contacts fetch error: \(error.localizedDescription)")
            return result
        }

        if orderByGivenName {
            contacts.sort {
                $0.givenName.lowercased() < $1.givenName.lowercased()
            }
        }

        for contact in contacts {
            result.append(
                contactToDictionary(
                    contact: contact,
                    localizedLabels: localizedLabels
                )
            )
        }

        return result
    }

    // MARK: - Helpers
    private func has(contact: CNContact, phone: String) -> Bool {
        if contact.phoneNumbers.isEmpty { return false }
        let phoneNumberToCompareAgainst = phone.components(
            separatedBy: CharacterSet.decimalDigits.inverted
        ).joined()
        for phoneNumber in contact.phoneNumbers {
            if let phoneNumberStruct = phoneNumber.value as CNPhoneNumber? {
                let phoneNumberString = phoneNumberStruct.stringValue
                let phoneNumberToCompare = phoneNumberString.components(
                    separatedBy: CharacterSet.decimalDigits.inverted
                ).joined()
                if phoneNumberToCompare == phoneNumberToCompareAgainst {
                    return true
                }
            }
        }
        return false
    }

    func addContact(contact: CNMutableContact) -> String {
        let store = CNContactStore()
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Presenting contact UI safely
    func openContactForm() -> [String: Any]? {
        let contact = CNMutableContact()
        let controller = CNContactViewController(forNewContact: contact)
        controller.delegate = self

        DispatchQueue.main.async {
            let navigation = UINavigationController(
                rootViewController: controller
            )
            guard
                let presenter = UIApplication.topViewController(
                    base: self.viewController
                )
            else {
                NSLog(
                    "contacts_service_plus: no presenter available to open new contact form"
                )
                return
            }
            presenter.present(navigation, animated: true, completion: nil)
        }
        return nil
    }

    func preloadContactView() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            NSLog("Preloading CNContactViewController")
            _ = CNContactViewController(forNewContact: nil)
        }
    }

    @objc func cancelContactForm() {
        if let pending = self.pendingResult {
            if let presenter = UIApplication.topViewController(
                base: self.viewController
            ) {
                presenter.dismiss(animated: true, completion: nil)
            }
            pending(SwiftContactsServicePlugin.FORM_OPERATION_CANCELED)
            self.pendingResult = nil
        }
    }

    public func contactViewController(
        _ viewController: CNContactViewController,
        didCompleteWith contact: CNContact?
    ) {
        viewController.dismiss(animated: true, completion: nil)
        if let pending = self.pendingResult {
            if let contact = contact {
                pending(
                    contactToDictionary(
                        contact: contact,
                        localizedLabels: localizedLabels
                    )
                )
            } else {
                pending(SwiftContactsServicePlugin.FORM_OPERATION_CANCELED)
            }
            self.pendingResult = nil
        }
    }

    func openExistingContact(
        contact: [String: Any],
        result: @escaping FlutterResult
    )
        -> [String: Any]?
    {
        let store = CNContactStore()
        guard let identifier = contact["identifier"] as? String else {
            result(SwiftContactsServicePlugin.FORM_COULD_NOT_BE_OPEN)
            return nil
        }

        let backTitle = contact["backTitle"] as? String
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactImageDataKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactViewController.descriptorForRequiredKeys(),
        ]

        do {
            let cnContact = try store.unifiedContact(
                withIdentifier: identifier,
                keysToFetch: keysToFetch
            )
            let viewController = CNContactViewController(for: cnContact)
            viewController.navigationItem.backBarButtonItem = UIBarButtonItem(
                title: backTitle ?? "Cancel",
                style: .plain,
                target: self,
                action: #selector(cancelContactForm)
            )
            viewController.delegate = self

            DispatchQueue.main.async {
                let navigation = UINavigationController(
                    rootViewController: viewController
                )
                guard
                    let presenter = UIApplication.topViewController(
                        base: self.viewController
                    )
                else {
                    NSLog(
                        "contacts_service_plus: no presenter available to open existing contact"
                    )
                    result(SwiftContactsServicePlugin.FORM_COULD_NOT_BE_OPEN)
                    return
                }

                var style: UIActivityIndicatorView.Style
                if #available(iOS 13.0, *) {
                    style = .medium
                } else {
                    style = .gray
                }

                let activityIndicatorView = UIActivityIndicatorView(
                    style: style
                )
                activityIndicatorView.frame = presenter.view.bounds
                activityIndicatorView.startAnimating()
                activityIndicatorView.backgroundColor = UIColor.white
                navigation.view.addSubview(activityIndicatorView)

                presenter.present(navigation, animated: true) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        activityIndicatorView.removeFromSuperview()
                    }
                }
            }

            return nil
        } catch {
            NSLog("openExistingContact error: \(error.localizedDescription)")
            result(SwiftContactsServicePlugin.FORM_COULD_NOT_BE_OPEN)
            return nil
        }
    }

    func openDeviceContactPicker(
        arguments: [String: Any],
        result: @escaping FlutterResult
    ) {
        localizedLabels = arguments["iOSLocalizedLabels"] as? Bool ?? true
        self.pendingResult = result

        let contactPicker = CNContactPickerViewController()
        contactPicker.delegate = self

        DispatchQueue.main.async {
            guard
                let presenter = UIApplication.topViewController(
                    base: self.viewController
                )
            else {
                NSLog(
                    "contacts_service_plus: no presenter available to open contact picker"
                )
                result(SwiftContactsServicePlugin.FORM_COULD_NOT_BE_OPEN)
                return
            }
            presenter.present(contactPicker, animated: true, completion: nil)
        }
    }

    // MARK: - CNContactPickerDelegate
    public func contactPicker(
        _ picker: CNContactPickerViewController,
        didSelect contact: CNContact
    ) {
        if let pending = self.pendingResult {
            pending(
                contactToDictionary(
                    contact: contact,
                    localizedLabels: localizedLabels
                )
            )
            self.pendingResult = nil
        }
    }

    public func contactPickerDidCancel(_ picker: CNContactPickerViewController)
    {
        if let pending = self.pendingResult {
            pending(SwiftContactsServicePlugin.FORM_OPERATION_CANCELED)
            self.pendingResult = nil
        }
    }

    // MARK: - Delete / Update
    func deleteContact(dictionary: [String: Any]) -> Bool {
        guard let identifier = dictionary["identifier"] as? String else {
            return false
        }
        let store = CNContactStore()
        let keys = [CNContactIdentifierKey as NSString]
        do {
            if let contact = try store.unifiedContact(
                withIdentifier: identifier,
                keysToFetch: keys
            ).mutableCopy() as? CNMutableContact {
                let request = CNSaveRequest()
                request.delete(contact)
                try store.execute(request)
            }
            return true
        } catch {
            NSLog("deleteContact error: \(error.localizedDescription)")
            return false
        }
    }

    func updateContact(dictionary: [String: Any]) -> Bool {
        guard let identifier = dictionary["identifier"] as? String else {
            return false
        }
        let store = CNContactStore()
        let keys: [Any] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactEmailAddressesKey,
            CNContactPhoneNumbersKey,
            CNContactFamilyNameKey,
            CNContactGivenNameKey,
            CNContactMiddleNameKey,
            CNContactNamePrefixKey,
            CNContactNameSuffixKey,
            CNContactPostalAddressesKey,
            CNContactOrganizationNameKey,
            CNContactImageDataKey,
            CNContactJobTitleKey,
        ]

        do {
            if let contact = try store.unifiedContact(
                withIdentifier: identifier,
                keysToFetch: keys as! [CNKeyDescriptor]
            ).mutableCopy() as? CNMutableContact {
                contact.givenName = dictionary["givenName"] as? String ?? ""
                contact.familyName = dictionary["familyName"] as? String ?? ""
                contact.middleName = dictionary["middleName"] as? String ?? ""
                contact.namePrefix = dictionary["prefix"] as? String ?? ""
                contact.nameSuffix = dictionary["suffix"] as? String ?? ""
                contact.organizationName =
                    dictionary["company"] as? String ?? ""
                contact.jobTitle = dictionary["jobTitle"] as? String ?? ""
                if let avatar =
                    (dictionary["avatar"] as? FlutterStandardTypedData)?.data
                {
                    contact.imageData = avatar
                }

                if let phoneNumbers = dictionary["phones"]
                    as? [[String: String]]
                {
                    var updatedPhoneNumbers = [CNLabeledValue<CNPhoneNumber>]()
                    for phone in phoneNumbers where phone["value"] != nil {
                        updatedPhoneNumbers.append(
                            CNLabeledValue(
                                label: getPhoneLabel(label: phone["label"]),
                                value: CNPhoneNumber(
                                    stringValue: phone["value"]!
                                )
                            )
                        )
                    }
                    contact.phoneNumbers = updatedPhoneNumbers
                }

                if let emails = dictionary["emails"] as? [[String: String]] {
                    var updatedEmails = [CNLabeledValue<NSString>]()
                    for email in emails where email["value"] != nil {
                        let emailLabel = email["label"] ?? ""
                        updatedEmails.append(
                            CNLabeledValue(
                                label: getCommonLabel(label: emailLabel),
                                value: email["value"]! as NSString
                            )
                        )
                    }
                    contact.emailAddresses = updatedEmails
                }

                if let postalAddresses = dictionary["postalAddresses"]
                    as? [[String: String]]
                {
                    var updatedPostalAddresses = [
                        CNLabeledValue<CNPostalAddress>
                    ]()
                    for postalAddress in postalAddresses {
                        let newAddress = CNMutablePostalAddress()
                        newAddress.street = postalAddress["street"] ?? ""
                        newAddress.city = postalAddress["city"] ?? ""
                        newAddress.postalCode = postalAddress["postcode"] ?? ""
                        newAddress.country = postalAddress["country"] ?? ""
                        newAddress.state = postalAddress["region"] ?? ""
                        let label = postalAddress["label"] ?? ""
                        updatedPostalAddresses.append(
                            CNLabeledValue(
                                label: getCommonLabel(label: label),
                                value: newAddress
                            )
                        )
                    }
                    contact.postalAddresses = updatedPostalAddresses
                }

                let request = CNSaveRequest()
                request.update(contact)
                try store.execute(request)
                return true
            }
        } catch {
            NSLog("updateContact error: \(error.localizedDescription)")
            return false
        }
        return false
    }

    // MARK: - Conversion helpers
    func dictionaryToContact(dictionary: [String: Any]) -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = dictionary["givenName"] as? String ?? ""
        contact.familyName = dictionary["familyName"] as? String ?? ""
        contact.middleName = dictionary["middleName"] as? String ?? ""
        contact.namePrefix = dictionary["prefix"] as? String ?? ""
        contact.nameSuffix = dictionary["suffix"] as? String ?? ""
        contact.organizationName = dictionary["company"] as? String ?? ""
        contact.jobTitle = dictionary["jobTitle"] as? String ?? ""
        if let avatarData = (dictionary["avatar"] as? FlutterStandardTypedData)?
            .data
        {
            contact.imageData = avatarData
        }

        if let phoneNumbers = dictionary["phones"] as? [[String: String]] {
            for phone in phoneNumbers where phone["value"] != nil {
                contact.phoneNumbers.append(
                    CNLabeledValue(
                        label: getPhoneLabel(label: phone["label"]),
                        value: CNPhoneNumber(stringValue: phone["value"]!)
                    )
                )
            }
        }

        if let emails = dictionary["emails"] as? [[String: String]] {
            for email in emails where email["value"] != nil {
                let emailLabel = email["label"] ?? ""
                contact.emailAddresses.append(
                    CNLabeledValue(
                        label: getCommonLabel(label: emailLabel),
                        value: email["value"]! as NSString
                    )
                )
            }
        }

        if let postalAddresses = dictionary["postalAddresses"]
            as? [[String: String]]
        {
            for postalAddress in postalAddresses {
                let newAddress = CNMutablePostalAddress()
                newAddress.street = postalAddress["street"] ?? ""
                newAddress.city = postalAddress["city"] ?? ""
                newAddress.postalCode = postalAddress["postcode"] ?? ""
                newAddress.country = postalAddress["country"] ?? ""
                newAddress.state = postalAddress["region"] ?? ""
                let label = postalAddress["label"] ?? ""
                contact.postalAddresses.append(
                    CNLabeledValue(
                        label: getCommonLabel(label: label),
                        value: newAddress
                    )
                )
            }
        }

        if let birthday = dictionary["birthday"] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: birthday) {
                contact.birthday = Calendar.current.dateComponents(
                    [.year, .month, .day],
                    from: date
                )
            }
        }

        return contact
    }

    func contactToDictionary(contact: CNContact, localizedLabels: Bool)
        -> [String: Any]
    {
        var result = [String: Any]()
        result["identifier"] = contact.identifier
        result["displayName"] = CNContactFormatter.string(
            from: contact,
            style: .fullName
        )
        result["givenName"] = contact.givenName
        result["familyName"] = contact.familyName
        result["middleName"] = contact.middleName
        result["prefix"] = contact.namePrefix
        result["suffix"] = contact.nameSuffix
        result["company"] = contact.organizationName
        result["jobTitle"] = contact.jobTitle

        if contact.isKeyAvailable(CNContactThumbnailImageDataKey),
            let avatarData = contact.thumbnailImageData
        {
            result["avatar"] = FlutterStandardTypedData(bytes: avatarData)
        }
        if contact.isKeyAvailable(CNContactImageDataKey),
            let avatarData = contact.imageData
        {
            result["avatar"] = FlutterStandardTypedData(bytes: avatarData)
        }

        var phoneNumbers = [[String: String]]()
        for phone in contact.phoneNumbers {
            var phoneDictionary = [String: String]()
            phoneDictionary["value"] = phone.value.stringValue
            phoneDictionary["label"] = "other"
            if let label = phone.label {
                phoneDictionary["label"] =
                    localizedLabels
                    ? CNLabeledValue<NSString>.localizedString(forLabel: label)
                    : getRawPhoneLabel(label)
            }
            phoneNumbers.append(phoneDictionary)
        }
        result["phones"] = phoneNumbers

        var emailAddresses = [[String: String]]()
        for email in contact.emailAddresses {
            var emailDictionary = [String: String]()
            emailDictionary["value"] = String(email.value)
            emailDictionary["label"] = "other"
            if let label = email.label {
                emailDictionary["label"] =
                    localizedLabels
                    ? CNLabeledValue<NSString>.localizedString(forLabel: label)
                    : getRawCommonLabel(label)
            }
            emailAddresses.append(emailDictionary)
        }
        result["emails"] = emailAddresses

        var postalAddresses = [[String: String]]()
        for address in contact.postalAddresses {
            var addressDictionary = [String: String]()
            addressDictionary["label"] = ""
            if let label = address.label {
                addressDictionary["label"] =
                    localizedLabels
                    ? CNLabeledValue<NSString>.localizedString(forLabel: label)
                    : getRawCommonLabel(label)
            }
            addressDictionary["street"] = address.value.street
            addressDictionary["city"] = address.value.city
            addressDictionary["postcode"] = address.value.postalCode
            addressDictionary["region"] = address.value.state
            addressDictionary["country"] = address.value.country
            postalAddresses.append(addressDictionary)
        }
        result["postalAddresses"] = postalAddresses

        if let birthday: Date = contact.birthday?.date {
            let formatter = DateFormatter()
            let year = Calendar.current.component(.year, from: birthday)
            formatter.dateFormat = year == 1 ? "--MM-dd" : "yyyy-MM-dd"
            result["birthday"] = formatter.string(from: birthday)
        }

        return result
    }

    // MARK: - Label helpers
    func getPhoneLabel(label: String?) -> String {
        let labelValue = label ?? ""
        switch labelValue {
        case "main": return CNLabelPhoneNumberMain
        case "mobile": return CNLabelPhoneNumberMobile
        case "iPhone": return CNLabelPhoneNumberiPhone
        case "work": return CNLabelWork
        case "home": return CNLabelHome
        case "other": return CNLabelOther
        default: return labelValue
        }
    }

    func getCommonLabel(label: String?) -> String {
        let labelValue = label ?? ""
        switch labelValue {
        case "work": return CNLabelWork
        case "home": return CNLabelHome
        case "other": return CNLabelOther
        default: return labelValue
        }
    }

    func getRawPhoneLabel(_ label: String?) -> String {
        let labelValue = label ?? ""
        switch labelValue {
        case CNLabelPhoneNumberMain: return "main"
        case CNLabelPhoneNumberMobile: return "mobile"
        case CNLabelPhoneNumberiPhone: return "iPhone"
        case CNLabelWork: return "work"
        case CNLabelHome: return "home"
        case CNLabelOther: return "other"
        default: return labelValue
        }
    }

    func getRawCommonLabel(_ label: String?) -> String {
        let labelValue = label ?? ""
        switch labelValue {
        case CNLabelWork: return "work"
        case CNLabelHome: return "home"
        case CNLabelOther: return "other"
        default: return labelValue
        }
    }
}

// MARK: - UIApplication helper to find top view controller in Scene-based apps
extension UIApplication {
    class func topViewController(base: UIViewController? = nil)
        -> UIViewController?
    {
        if let base = base {
            return topViewControllerFrom(base: base)
        }

        if #available(iOS 13.0, *) {
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }

            for scene in scenes {
                if let root = scene.windows.first(where: { $0.isKeyWindow })?
                    .rootViewController
                {
                    return topViewControllerFrom(base: root)
                }
            }

            for scene in UIApplication.shared.connectedScenes.compactMap({
                $0 as? UIWindowScene
            }) {
                if let root = scene.windows.first?.rootViewController {
                    return topViewControllerFrom(base: root)
                }
            }
        }

        for window in UIApplication.shared.windows
        where window.rootViewController != nil {
            return topViewControllerFrom(base: window.rootViewController)
        }

        return nil
    }

    private class func topViewControllerFrom(base: UIViewController?)
        -> UIViewController?
    {
        if let nav = base as? UINavigationController {
            return topViewControllerFrom(base: nav.visibleViewController)
        }
        if let tab = base as? UITabBarController,
            let selected = tab.selectedViewController
        {
            return topViewControllerFrom(base: selected)
        }
        if let presented = base?.presentedViewController {
            return topViewControllerFrom(base: presented)
        }
        return base
    }
}
