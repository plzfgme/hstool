const std = @import("std");
const hstool = @import("hstool");

test "getBearerToken" {
    const allocator = std.testing.allocator;
    const token = try hstool.api.getBearerToken(allocator);
    defer allocator.free(token);
}

test "fetchMetadataBySet" {
    const allocator = std.testing.allocator;
    const token = try hstool.api.getBearerToken(allocator);
    defer allocator.free(token);

    const metadata = try hstool.api.fetchMetadataBySet(allocator, .{
        .bearer_token = token,
        .set = .spell_schools,
    });
    defer metadata.deinit();
}

test "fetchCardById" {
    const allocator = std.testing.allocator;
    const token = try hstool.api.getBearerToken(allocator);
    defer allocator.free(token);

    const card = try hstool.api.fetchCardById(allocator, .{
        .bearer_token = token,
        .card_id = 678,
    });
    defer card.deinit();
}

test "searchCardsPaged" {
    const allocator = std.testing.allocator;
    const token = try hstool.api.getBearerToken(allocator);
    defer allocator.free(token);

    const cards = try hstool.api.searchCardsPaged(allocator, .{
        .bearer_token = token,
        .class = "hunter",
        .game_mode = "standard",
        .page = 5,
        .page_size = 40,
    });
    defer cards.deinit();
}

test "searchCards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const token = try hstool.api.getBearerToken(allocator);
    defer allocator.free(token);

    const cards = try hstool.api.searchCards(allocator, .{
        .bearer_token = token,
        .class = "hunter",
        .game_mode = "standard",
    });
    defer cards.deinit();
}
