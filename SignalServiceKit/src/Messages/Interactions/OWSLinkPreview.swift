//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit

@objc
public enum LinkPreviewError: Int, Error {
    /// A preview could not be generated from available input
    case noPreview
    /// A preview should have been generated, but something unexpected caused it to fail
    case invalidPreview
    /// A preview could not be generated due to an issue fetching a network resource
    case fetchFailure
    /// A preview could not be generated because the feature is disabled
    case featureDisabled
}

// MARK: - OWSLinkPreviewDraft

// This contains the info for a link preview "draft".
public class OWSLinkPreviewDraft: NSObject {
    @objc
    public var url: URL

    @objc
    public var urlString: String {
        return url.absoluteString
    }

    @objc
    public var title: String?

    @objc
    public var imageData: Data?

    @objc
    public var imageMimeType: String?

    @objc
    public var previewDescription: String?

    @objc
    public var date: Date?

    public init(url: URL, title: String?, imageData: Data? = nil, imageMimeType: String? = nil) {
        self.url = url
        self.title = title
        self.imageData = imageData
        self.imageMimeType = imageMimeType

        super.init()
    }

    fileprivate func isValid() -> Bool {
        var hasTitle = false
        if let titleValue = title {
            hasTitle = titleValue.count > 0
        }
        let hasImage = imageData != nil && imageMimeType != nil
        return hasTitle || hasImage
    }

    @objc
    public func displayDomain() -> String? {
        return OWSLinkPreviewManager.displayDomain(forUrl: urlString)
    }
}

// MARK: - OWSLinkPreview

@objc
public class OWSLinkPreview: MTLModel {

    @objc
    public var urlString: String?

    @objc
    public var title: String?

    @objc
    public var imageAttachmentId: String?

    @objc
    public var previewDescription: String?

    @objc
    public var date: Date?

    @objc
    public init(urlString: String, title: String?, imageAttachmentId: String?) {
        self.urlString = urlString
        self.title = title
        self.imageAttachmentId = imageAttachmentId

        super.init()
    }

    @objc
    public override init() {
        super.init()
    }

    @objc
    public required init!(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc
    public required init(dictionary dictionaryValue: [String: Any]!) throws {
        try super.init(dictionary: dictionaryValue)
    }

    @objc
    public class func isNoPreviewError(_ error: Error) -> Bool {
        guard let error = error as? LinkPreviewError else {
            return false
        }
        return error == .noPreview
    }

    @objc
    public class func buildValidatedLinkPreview(dataMessage: SSKProtoDataMessage,
                                                body: String?,
                                                transaction: SDSAnyWriteTransaction) throws -> OWSLinkPreview {
        guard let previewProto = dataMessage.preview.first else {
            throw LinkPreviewError.noPreview
        }
        guard dataMessage.attachments.count < 1 else {
            Logger.error("Discarding link preview; message has attachments.")
            throw LinkPreviewError.invalidPreview
        }
        let urlString = previewProto.url

        guard let url = URL(string: urlString), url.isPermittedLinkPreviewUrl() else {
            Logger.error("Could not parse preview url.")
            throw LinkPreviewError.invalidPreview
        }

        guard let body = body, body.contains(urlString) else {
            Logger.error("Url not present in body")
            throw LinkPreviewError.invalidPreview
        }

        var title: String?
        var previewDescription: String?
        if let rawTitle = previewProto.title {
            let normalizedTitle = normalizeString(rawTitle, maxLines: 2)
            if normalizedTitle.count > 0 {
                title = normalizedTitle
            }
        }
        if let rawDescription = previewProto.previewDescription, previewProto.title != previewProto.previewDescription {
            let normalizedDescription = normalizeString(rawDescription, maxLines: 3)
            if normalizedDescription.count > 0 {
                previewDescription = normalizedDescription
            }
        }

        var imageAttachmentId: String?
        if let imageProto = previewProto.image {
            if let imageAttachmentPointer = TSAttachmentPointer(fromProto: imageProto, albumMessage: nil) {
                imageAttachmentPointer.anyInsert(transaction: transaction)
                imageAttachmentId = imageAttachmentPointer.uniqueId
            } else {
                Logger.error("Could not parse image proto.")
                throw LinkPreviewError.invalidPreview
            }
        }

        let linkPreview = OWSLinkPreview(urlString: urlString, title: title, imageAttachmentId: imageAttachmentId)

        linkPreview.previewDescription = previewDescription
        if previewProto.hasDate {
            linkPreview.date = Date(millisecondsSince1970: previewProto.date)
        }

        guard linkPreview.isValid() else {
            Logger.error("Preview has neither title nor image.")
            throw LinkPreviewError.invalidPreview
        }

        return linkPreview
    }

    @objc
    public class func buildValidatedLinkPreview(fromInfo info: OWSLinkPreviewDraft,
                                                transaction: SDSAnyWriteTransaction) throws -> OWSLinkPreview {
        guard SSKPreferences.areLinkPreviewsEnabled(transaction: transaction) else {
            throw LinkPreviewError.featureDisabled
        }
        let imageAttachmentId = OWSLinkPreview.saveAttachmentIfPossible(imageData: info.imageData,
                                                                        imageMimeType: info.imageMimeType,
                                                                        transaction: transaction)

        let linkPreview = OWSLinkPreview(urlString: info.urlString, title: info.title, imageAttachmentId: imageAttachmentId)
        linkPreview.previewDescription = info.previewDescription
        linkPreview.date = info.date

        guard linkPreview.isValid() else {
            owsFailDebug("Preview has neither title nor image.")
            throw LinkPreviewError.invalidPreview
        }

        return linkPreview
    }

    private class func saveAttachmentIfPossible(imageData: Data?,
                                                imageMimeType: String?,
                                                transaction: SDSAnyWriteTransaction) -> String? {
        guard let imageData = imageData else {
            return nil
        }
        guard let imageMimeType = imageMimeType else {
            return nil
        }
        guard let fileExtension = MIMETypeUtil.fileExtension(forMIMEType: imageMimeType) else {
            return nil
        }
        let fileSize = imageData.count
        guard fileSize > 0 else {
            owsFailDebug("Invalid file size for image data.")
            return nil
        }
        let contentType = imageMimeType

        let fileUrl = OWSFileSystem.temporaryFileUrl(fileExtension: fileExtension)
        do {
            try imageData.write(to: fileUrl)
            let dataSource = try DataSourcePath.dataSource(with: fileUrl, shouldDeleteOnDeallocation: true)
            let attachment = TSAttachmentStream(contentType: contentType, byteCount: UInt32(fileSize), sourceFilename: nil, caption: nil, albumMessageId: nil)
            try attachment.writeConsumingDataSource(dataSource)
            attachment.anyInsert(transaction: transaction)

            return attachment.uniqueId
        } catch {
            owsFailDebug("Could not write data source for: \(fileUrl), error: \(error)")
            return nil
        }
    }

    private func isValid() -> Bool {
        var hasTitle = false
        if let titleValue = title {
            hasTitle = titleValue.count > 0
        }
        let hasImage = imageAttachmentId != nil
        return hasTitle || hasImage
    }

    @objc
    public func removeAttachment(transaction: SDSAnyWriteTransaction) {
        guard let imageAttachmentId = imageAttachmentId else {
            owsFailDebug("No attachment id.")
            return
        }
        guard let attachment = TSAttachment.anyFetch(uniqueId: imageAttachmentId, transaction: transaction) else {
            owsFailDebug("Could not load attachment.")
            return
        }
        attachment.anyRemove(transaction: transaction)
    }

    @objc
    public func displayDomain() -> String? {
        return OWSLinkPreviewManager.displayDomain(forUrl: urlString)
    }
}

@objc
public class OWSLinkPreviewManager: NSObject {

    // Although link preview fetches are non-blocking, the user may still end up
    // waiting for the fetch to complete. Because of this, UserInitiated is likely
    // most appropriate QoS.
    static let workQueue: DispatchQueue = .sharedUserInitiated

    // MARK: - Dependencies

    var databaseStorage: SDSDatabaseStorage {
        return SDSDatabaseStorage.shared
    }

    // MARK: - Public

    @objc(findFirstValidUrlInSearchString:)
    public func findFirstValidUrl(in searchString: String) -> URL? {
        guard areLinkPreviewsEnabledWithSneakyTransaction() else { return nil }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            owsFailDebug("Could not create NSDataDetector")
            return nil
        }

        let allMatches = detector.matches(
            in: searchString,
            options: [],
            range: NSRange(searchString.startIndex..<searchString.endIndex, in: searchString))

        return allMatches.first(where: {
            guard let parsedUrl = $0.url else { return false }
            guard let matchedRange = Range($0.range, in: searchString) else { return false }
            let matchedString = String(searchString[matchedRange])
            return parsedUrl.isPermittedLinkPreviewUrl(parsedFrom: matchedString)
        })?.url
    }

    @objc(fetchLinkPreviewForUrl:)
    public func fetchLinkPreview(for url: URL) -> AnyPromise {
        let promise: Promise<OWSLinkPreviewDraft> = fetchLinkPreview(for: url)
        return AnyPromise(promise)
    }

    public func fetchLinkPreview(for url: URL) -> Promise<OWSLinkPreviewDraft> {
        guard areLinkPreviewsEnabledWithSneakyTransaction() else {
            return Promise(error: LinkPreviewError.featureDisabled)
        }

        if StickerPackInfo.isStickerPackShare(url) {
            return fetchLinkPreview(forStickerPackUrl: url)
        } else {
            return fetchLinkPreview(forGenericUrl: url)
        }
    }

    // MARK: - Private

    private func fetchLinkPreview(forStickerPackUrl url: URL) -> Promise<OWSLinkPreviewDraft> {
        firstly(on: Self.workQueue) {
            self.linkPreviewDraft(forStickerShare: url)

        }.map(on: Self.workQueue) { (linkPreviewDraft) -> OWSLinkPreviewDraft in
            guard linkPreviewDraft.isValid() else {
                throw LinkPreviewError.noPreview
            }
            return linkPreviewDraft
        }
    }

    private func fetchLinkPreview(forGenericUrl url: URL) -> Promise<OWSLinkPreviewDraft> {
        firstly(on: Self.workQueue) { () -> Promise<(URL, String)> in
            self.fetchStringResource(from: url)

        }.then(on: Self.workQueue) { (respondingUrl, rawHTML) -> Promise<(OWSLinkPreviewDraft, Data?)> in
            let content = HTMLMetadata.construct(parsing: rawHTML)
            let rawTitle = content.ogTitle ?? content.titleTag
            let normalizedTitle = rawTitle.map { normalizeString($0, maxLines: 2) }
            let draft = OWSLinkPreviewDraft(url: url, title: normalizedTitle)

            let rawDescription = content.ogDescription ?? content.description
            if rawDescription != rawTitle, let description = rawDescription {
                draft.previewDescription = normalizeString(description, maxLines: 3)
            }

            draft.date = content.dateForLinkPreview

            guard let imageUrlString = content.ogImageUrlString ?? content.faviconUrlString,
                  let imageUrl = URL(string: imageUrlString, relativeTo: respondingUrl) else {
                return Promise.value((draft, nil))
            }

            return firstly(on: Self.workQueue) { () -> Promise<Data> in
                self.fetchImageResource(from: imageUrl)
            }.map(on: Self.workQueue) { data -> (OWSLinkPreviewDraft, Data?) in
                return (draft, data)
            }.recover(on: Self.workQueue) { _ -> Promise<(OWSLinkPreviewDraft, Data?)> in
                return Promise.value((draft, nil))
            }

        }.map(on: Self.workQueue) { (draft, imageData) -> OWSLinkPreviewDraft in
            draft.imageData = imageData
            draft.imageMimeType = OWSMimeTypeImageJpeg
            guard draft.isValid() else {
                throw LinkPreviewError.noPreview
            }
            return draft
        }

    }

    // MARK: - Private, Utilities

    func areLinkPreviewsEnabledWithSneakyTransaction() -> Bool {
        return databaseStorage.read { transaction in
            SSKPreferences.areLinkPreviewsEnabled(transaction: transaction)
        }
    }

    // MARK: - Private, Networking

    private func createSessionManager() -> AFHTTPSessionManager {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.urlCache = nil
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData

        let sessionManager = AFHTTPSessionManager(sessionConfiguration: sessionConfig)
        sessionManager.requestSerializer = AFHTTPRequestSerializer()
        sessionManager.responseSerializer = AFHTTPResponseSerializer()

        sessionManager.setDataTaskDidReceiveResponseBlock { (_, _, response) -> URLSession.ResponseDisposition in
            let anticipatedSize = response.expectedContentLength
            if anticipatedSize == NSURLSessionTransferSizeUnknown || anticipatedSize < Self.maxFetchedContentSize {
                return .allow
            } else {
                return .cancel
            }
        }
        sessionManager.setDataTaskDidReceiveDataBlock { (_, task, _) in
            let fetchedBytes = task.countOfBytesReceived
            if fetchedBytes >= Self.maxFetchedContentSize {
                task.cancel()
            }
        }
        sessionManager.setTaskWillPerformHTTPRedirectionBlock { (_, _, _, request) -> URLRequest? in
            if request.url?.isPermittedLinkPreviewUrl() == true {
                return request
            } else {
                return nil
            }
        }
        sessionManager.requestSerializer.setValue(Self.userAgentString, forHTTPHeaderField: "User-Agent")
        return sessionManager

    }

    func fetchStringResource(from url: URL) -> Promise<(URL, String)> {
        firstly(on: Self.workQueue) { () -> Promise<(task: URLSessionDataTask, responseObject: Any?)> in
            let sessionManager = self.createSessionManager()
            return sessionManager.getPromise(url.absoluteString)

        }.map(on: Self.workQueue) { (task: URLSessionDataTask, responseObject: Any?) -> (URL, String) in
            guard let response = task.response as? HTTPURLResponse,
                  let respondingUrl = response.url,
                  response.statusCode >= 200 && response.statusCode < 300 else {
                Logger.warn("Invalid response: \(type(of: task.response)).")
                throw LinkPreviewError.fetchFailure
            }

            guard let data = responseObject as? Data,
                  let string = String(data: data, urlResponse: response),
                  string.count > 0 else {
                Logger.warn("Response object could not be parsed")
                throw LinkPreviewError.invalidPreview
            }

            return (respondingUrl, string)
        }
    }

    private func fetchImageResource(from url: URL) -> Promise<Data> {
        firstly(on: Self.workQueue) { () -> Promise<(task: URLSessionDataTask, responseObject: Any?)> in
            let sessionManager = self.createSessionManager()
            return sessionManager.getPromise(url.absoluteString)

        }.map(on: Self.workQueue) { (task: URLSessionDataTask, responseObject: Any?) -> Data in
            try autoreleasepool {
                guard let response = task.response as? HTTPURLResponse,
                      response.statusCode >= 200 && response.statusCode < 300 else {
                    Logger.warn("Invalid response: \(type(of: task.response)).")
                    throw LinkPreviewError.fetchFailure
                }
                guard let rawData = responseObject as? Data,
                      rawData.count < Self.maxFetchedContentSize else {

                    Logger.warn("Response object could not be parsed")
                    throw LinkPreviewError.invalidPreview
                }

                let imageData = (rawData as NSData).imageData(withPath: nil, mimeType: nil)
                guard imageData.isValid,
                      imageData.pixelSize.height > 0,
                      imageData.pixelSize.width > 0,
                      let image = UIImage(data: rawData) else {
                    Logger.warn("Invalid image data")
                    throw LinkPreviewError.invalidPreview
                }

                let maxDimension: CGFloat = 1024

                let scaledImage: UIImage?
                if imageData.pixelSize.height > maxDimension || imageData.pixelSize.width > maxDimension {
                    scaledImage = image.resized(withMaxDimensionPixels: 1024)
                } else {
                    scaledImage = image
                }
                let compressedImageData = scaledImage?.jpegData(compressionQuality: 0.8)

                if let compressedImageData = compressedImageData {
                    return compressedImageData
                } else {
                    Logger.error("Failed to resize/compress image.")
                    throw LinkPreviewError.invalidPreview
                }
            }
        }
    }

    // MARK: - Private, Constants

    private static let maxFetchedContentSize = 2 * 1024 * 1024
    private static let allowedMIMETypes: Set = [OWSMimeTypeImagePng, OWSMimeTypeImageJpeg]

    // Twitter doesn't return OpenGraph tags to Signal
    // `curl -A Signal "https://twitter.com/signalapp/status/1280166087577997312?s=20"`
    // If this ever changes, we can switch back to our default User-Agent
    private static let userAgentString = "WhatsApp"

    // MARK: - Stickers

    func linkPreviewDraft(forStickerShare url: URL) -> Promise<OWSLinkPreviewDraft> {
        Logger.verbose("url: \(url)")

        guard let stickerPackInfo = StickerPackInfo.parseStickerPackShare(url) else {
            Logger.error("Could not parse url.")
            return Promise(error: LinkPreviewError.invalidPreview)
        }

        // tryToDownloadStickerPack will use locally saved data if possible.
        return firstly(on: Self.workQueue) {
            StickerManager.tryToDownloadStickerPack(stickerPackInfo: stickerPackInfo)

        }.then(on: Self.workQueue) { (stickerPack) -> Promise<OWSLinkPreviewDraft> in
            let coverInfo = stickerPack.coverInfo
            // tryToDownloadSticker will use locally saved data if possible.
            return StickerManager.tryToDownloadSticker(stickerPack: stickerPack, stickerInfo: coverInfo).map(on: DispatchQueue.global()) { (coverData) -> OWSLinkPreviewDraft in
                // Try to build thumbnail from cover webp.
                var pngImageData: Data?
                if let stillImage = (coverData as NSData).stillForWebpData() {
                    var stillThumbnail = stillImage
                    let maxImageSize: CGFloat = 1024
                    let imageSize = stillImage.size
                    let shouldResize = imageSize.width > maxImageSize || imageSize.height > maxImageSize
                    if shouldResize {
                        if let resizedImage = stillImage.resized(withMaxDimensionPoints: maxImageSize) {
                            stillThumbnail = resizedImage
                        } else {
                            owsFailDebug("Could not resize image.")
                        }
                    }

                    if let stillData = stillThumbnail.pngData() {
                        pngImageData = stillData
                    } else {
                        owsFailDebug("Could not encode as JPEG.")
                    }
                } else {
                    owsFailDebug("Could not extract still.")
                }

                return OWSLinkPreviewDraft(url: url,
                                           title: stickerPack.title?.filterForDisplay,
                                           imageData: pngImageData,
                                           imageMimeType: OWSMimeTypeImagePng)
            }
        }
    }
}

fileprivate extension URL {
    private static let schemeAllowSet: Set = ["https"]
    private static let tldRejectSet: Set = ["onion"]
    private static let urlDelimeters: Set<Character> = Set(":/?#[]@")

    var mimeType: String? {
        guard pathExtension.count > 0 else {
            return nil
        }
        guard let mimeType = MIMETypeUtil.mimeType(forFileExtension: pathExtension) else {
            Logger.error("Image url has unknown content type: \(pathExtension).")
            return nil
        }
        return mimeType
    }

    /// Helper method that validates:
    /// - TLD is permitted
    /// - Comprised of valid character set
    static private func isValidHostname(_ hostname: String) -> Bool {
        // Technically, a TLD separator can be something other than a period (e.g. https://一二三。中国)
        // But it looks like NSURL/NSDataDetector won't even parse that. So we'll require periods for now
        let hostnameComponents = hostname.split(separator: ".")
        guard hostnameComponents.count >= 2, let tld = hostnameComponents.last?.lowercased() else {
            return false
        }
        let isValidTLD = !Self.tldRejectSet.contains(tld)
        let isAllASCII = hostname.allSatisfy { $0.isASCII }
        let isAllNonASCII = hostname.allSatisfy { !$0.isASCII || $0 == "." }

        return isValidTLD && (isAllASCII || isAllNonASCII)
    }

    /// - Parameter sourceString: The raw string that this URL was parsed from
    /// The source string will be parsed to ensure that the parsed hostname has only ASCII or non-ASCII characters
    /// to avoid homograph URLs.
    ///
    /// The source string is necessary, since NSURL and NSDataDetector will automatically punycode any returned
    /// URLs. The source string will be used to verify that the originating string's host only contained ASCII or
    /// non-ASCII characters to avoid homographs.
    ///
    /// If no sourceString is provided, the validated host will be whatever is returned from `host`, which will always
    /// be ASCII.
    func isPermittedLinkPreviewUrl(parsedFrom sourceString: String? = nil) -> Bool {
        guard let scheme = scheme?.lowercased(), scheme.count > 0 else { return false }
        guard user == nil else { return false }
        guard password == nil else { return false }
        let rawHostname: String?

        if let sourceString = sourceString {
            let schemePrefix = "\(scheme)://"
            rawHostname = sourceString
                .dropFirst(schemePrefix.count)
                .split(maxSplits: 1, whereSeparator: { Self.urlDelimeters.contains($0) }).first
                .map { String($0) }
        } else {
            // The hostname will be punycode and all ASCII
            rawHostname = host
        }

        guard let hostnameToValidate = rawHostname else { return false }
        return Self.schemeAllowSet.contains(scheme) && Self.isValidHostname(hostnameToValidate)
    }
}

fileprivate extension HTMLMetadata {
    var dateForLinkPreview: Date? {
        [ogPublishDateString, articlePublishDateString, ogModifiedDateString, articleModifiedDateString]
            .first(where: {$0 != nil})?
            .flatMap { Date.ows_parseFromISO8601String($0) }
    }
}

// MARK: - To be moved
// Everything after this line should find a new home at some point

fileprivate extension OWSLinkPreviewManager {
    @objc
    class func displayDomain(forUrl urlString: String?) -> String? {
        guard let urlString = urlString else {
            owsFailDebug("Missing url.")
            return nil
        }
        guard let url = URL(string: urlString) else {
            owsFailDebug("Invalid url.")
            return nil
        }
        if StickerPackInfo.isStickerPackShare(url) {
            return stickerPackShareDomain(forUrl: url)
        }
        return url.host
    }

    private class func stickerPackShareDomain(forUrl url: URL) -> String? {
        guard let domain = url.host?.lowercased() else {
            return nil
        }
        guard url.path.count > 1 else {
            // Url must have non-empty path.
            return nil
        }
        return domain
    }
}

private func normalizeString(_ string: String, maxLines: Int) -> String {
    var result = string
    var components = result.components(separatedBy: .newlines)
    if components.count > maxLines {
        components = Array(components[0..<maxLines])
        result =  components.joined(separator: "\n")
    }
    let maxCharacterCount = 2048
    if result.count > maxCharacterCount {
        let endIndex = result.index(result.startIndex, offsetBy: maxCharacterCount)
        result = String(result[..<endIndex])
    }
    return result.filterStringForDisplay()
}
