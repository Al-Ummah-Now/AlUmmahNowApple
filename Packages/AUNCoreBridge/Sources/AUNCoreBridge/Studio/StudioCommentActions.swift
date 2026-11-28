import Foundation

extension NativeStudioService {
    private struct ModerationBody: Encodable {
        struct Item: Encodable {
            let kind: HeldCommentKind
            let targetId: String
            let commentId: String
        }

        let action: HeldCommentModeration
        let items: [Item]
    }

    private struct ModerationResponse: Decodable {
        struct Result: Decodable {
            let commentId: String
            let ok: Bool
            let error: String?
        }

        let success: Bool
        let results: [Result]
    }

    public func moderateHeldComment(_ comment: HeldComment, action: HeldCommentModeration, channelID: String, accountID: String)
        async throws
    {
        guard let kind = comment.kind, let targetID = comment.targetID else { throw CoreError.notFound }
        let body = ModerationBody(action: action, items: [.init(kind: kind, targetId: targetID, commentId: comment.id)])
        let response = try await client.send(
            .post, "/api/channels/\(try Self.checkedSegment(channelID))/comments/bulk", channelID: channelID, body: body,
            accountID: accountID,
            as: ModerationResponse.self)
        guard response.success, let result = response.results.first, result.commentId == comment.id else {
            throw CoreError.decoding
        }
        guard result.ok else {
            switch result.error {
            case "not_found", "not_in_channel": throw CoreError.notFound
            case "forbidden": throw CoreError.forbidden
            case "removed", "held_by_moderation": throw CoreError.conflict(result.error ?? "")
            case "failed": throw CoreError.http(status: 500)
            default: throw CoreError.decoding
            }
        }
    }

    private struct ReportBody: Encodable {
        let entityType = "comment"
        let entityId: String
        let reason: CommentReportReason
        let description: String?
    }

    private struct BlockBody: Encodable {
        let userId: String
    }

    private struct ActionResponse: Decodable {
        let success: Bool
    }

    public func reportHeldComment(id: String, reason: CommentReportReason, description: String?, accountID: String) async throws {
        let body = ReportBody(entityId: id, reason: reason, description: description)
        // Reporting belongs to the signed-in person. The Studio channel may belong to someone else.
        let response = try await client.send(
            .post, "/api/moderation/reports", body: body, accountID: accountID, as: ActionResponse.self)
        guard response.success else { throw CoreError.decoding }
    }

    public func hideCommentAuthor(userID: String, channelID: String, accountID: String) async throws {
        let response = try await client.send(
            .post, "/api/channels/\(try Self.checkedSegment(channelID))/blocks", channelID: channelID,
            body: BlockBody(userId: userID),
            accountID: accountID,
            as: ActionResponse.self)
        guard response.success else { throw CoreError.decoding }
    }
}
