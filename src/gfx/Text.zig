const std = @import("std");
const mach = @import("../main.zig");
const gpu = mach.gpu;
const gfx = mach.gfx;

const math = mach.math;
const vec2 = math.vec2;
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec4 = math.vec4;
const Mat3x3 = math.Mat3x3;
const Mat4x4 = math.Mat4x4;

pub const name = .mach_gfx_text;
pub const Mod = mach.Mod(@This());

pub const components = .{
    .transform = .{ .type = Mat4x4, .description = 
    \\ The text model transformation matrix. Text is measured in pixel units, starting from
    \\ (0, 0) at the top-left corner and extending to the size of the text. By default, the world
    \\ origin (0, 0) lives at the center of the window.
    },

    .text = .{ .type = []const []const u8, .description = 
    \\ String segments of UTF-8 encoded text to render.
    \\
    \\ Expected to match the length of the style component.
    },

    .style = .{ .type = []const mach.EntityID, .description = 
    \\ The style to apply to each segment of text.
    \\
    \\ Expected to match the length of the text component.
    },

    .dirty = .{ .type = bool, .description = 
    \\ If true, the underlying glyph buffers, texture atlas, and transform buffers will be updated
    \\ as needed to reflect the latest component values.
    \\
    \\ This lets rendering be static if no changes have occurred.
    },

    .pipeline = .{ .type = mach.EntityID, .description = 
    \\ Which render pipeline to use for rendering the text.
    \\
    \\ This determines which shader, textures, etc. are used for rendering the text.
    },

    .built = .{ .type = BuiltText, .description = "internal" },
};

pub const local_events = .{
    .update = .{ .handler = update },
};

const BuiltText = struct {
    glyphs: std.ArrayListUnmanaged(gfx.TextPipeline.Glyph),
};

fn update(core: *mach.Core.Mod, text: *Mod, text_pipeline: *gfx.TextPipeline.Mod) !void {
    var archetypes_iter = text_pipeline.entities.query(.{ .all = &.{
        .{ .mach_gfx_text_pipeline = &.{
            .built,
        } },
    } });
    while (archetypes_iter.next()) |archetype| {
        const ids = archetype.slice(.entity, .id);
        const built_pipelines = archetype.slice(.mach_gfx_text_pipeline, .built);
        for (ids, built_pipelines) |pipeline_id, *built| {
            try updatePipeline(core, text, text_pipeline, pipeline_id, built);
        }
    }
}

fn updatePipeline(
    core: *mach.Core.Mod,
    text: *Mod,
    text_pipeline: *gfx.TextPipeline.Mod,
    pipeline_id: mach.EntityID,
    built: *gfx.TextPipeline.BuiltPipeline,
) !void {
    const device = core.state().device;
    const encoder = device.createCommandEncoder(null);
    defer encoder.release();

    const allocator = text_pipeline.state().allocator;
    var glyphs = if (text_pipeline.state().glyph_update_buffer) |*b| b else blk: {
        // TODO(text): better default allocation size
        const b = try std.ArrayListUnmanaged(gfx.TextPipeline.Glyph).initCapacity(allocator, 256);
        text_pipeline.state().glyph_update_buffer = b;
        break :blk &text_pipeline.state().glyph_update_buffer.?;
    };
    glyphs.clearRetainingCapacity();

    var texture_update = false;
    var num_texts: u32 = 0;
    var removes = try std.ArrayListUnmanaged(mach.EntityID).initCapacity(allocator, 8);
    var archetypes_iter = text.entities.query(.{ .all = &.{
        .{ .mach_gfx_text = &.{
            .transform,
            .text,
            .style,
            .pipeline,
        } },
    } });
    while (archetypes_iter.next()) |archetype| {
        const ids = archetype.slice(.entity, .id);
        const transforms = archetype.slice(.mach_gfx_text, .transform);
        const segment_slices = archetype.slice(.mach_gfx_text, .text);
        const style_slices = archetype.slice(.mach_gfx_text, .style);
        const pipelines = archetype.slice(.mach_gfx_text, .pipeline);

        // TODO: currently we cannot query all texts which have a _single_ pipeline component
        // value and get back contiguous memory for all of them. This is because all texts with
        // possibly different pipeline component values are stored as the same archetype. If we
        // introduce a new concept of tagging-by-value to our entity storage then we can enforce
        // that all entities with the same pipeline value are stored in contiguous memory, and
        // skip this copy.
        for (ids, transforms, segment_slices, style_slices, pipelines) |id, transform, segments, styles, text_pipeline_id| {
            if (text_pipeline_id != pipeline_id) continue;

            gfx.TextPipeline.cp_transforms[num_texts] = transform;

            if (text.get(id, .dirty) == null) {
                // We do not need to rebuild this specific entity, so use cached glyph information
                // from its previous build.
                const built_text = text.get(id, .built).?;
                for (built_text.glyphs.items) |*glyph| glyph.text_index = num_texts;
                try glyphs.appendSlice(allocator, built_text.glyphs.items);
                num_texts += 1;
                continue;
            }

            // Where we will store the built glyphs for this text entity.
            var built_text = if (text.get(id, .built)) |bt| bt else BuiltText{
                // TODO: better default allocations
                .glyphs = try std.ArrayListUnmanaged(gfx.TextPipeline.Glyph).initCapacity(allocator, 64),
            };
            built_text.glyphs.clearRetainingCapacity();

            const px_density = 2.0; // TODO(text): do not hard-code pixel density
            var origin_x: f32 = 0.0;
            var origin_y: f32 = 0.0;

            for (segments, styles) |segment, style| {
                // Load the font
                // TODO(text): allow specifying a font
                // TODO(text): keep fonts around for reuse later
                const font_name = core.entities.getComponent(style, .mach_gfx_text_style, .font_name).?;
                _ = font_name; // TODO: actually use font name
                const font_bytes = @import("font-assets").fira_sans_regular_ttf;
                var font = try gfx.Font.initBytes(font_bytes);
                defer font.deinit(allocator);

                // TODO(text): respect these style parameters
                const font_size = core.entities.getComponent(style, .mach_gfx_text_style, .font_size).?;
                const font_weight = core.entities.getComponent(style, .mach_gfx_text_style, .font_weight);
                _ = font_weight; // autofix
                const italic = core.entities.getComponent(style, .mach_gfx_text_style, .italic);
                _ = italic; // autofix
                const color = core.entities.getComponent(style, .mach_gfx_text_style, .color);
                _ = color; // autofix

                // Create a text shaper
                var run = try gfx.TextRun.init();
                run.font_size_px = font_size;
                run.px_density = px_density;
                defer run.deinit();

                run.addText(segment);
                try font.shape(&run);

                while (run.next()) |glyph| {
                    const codepoint = segment[glyph.cluster];
                    // TODO: use flags(?) to detect newline, or at least something more reliable?
                    if (codepoint == '\n') {
                        origin_x = 0;
                        origin_y -= font_size;
                        continue;
                    }

                    const region = try built.regions.getOrPut(allocator, .{
                        .index = glyph.glyph_index,
                        .size = @bitCast(font_size),
                    });
                    if (!region.found_existing) {
                        const rendered_glyph = try font.render(allocator, glyph.glyph_index, .{
                            .font_size_px = run.font_size_px,
                        });
                        if (rendered_glyph.bitmap) |bitmap| {
                            var glyph_atlas_region = try built.texture_atlas.reserve(allocator, rendered_glyph.width, rendered_glyph.height);
                            built.texture_atlas.set(glyph_atlas_region, @as([*]const u8, @ptrCast(bitmap.ptr))[0 .. bitmap.len * 4]);
                            texture_update = true;

                            // Exclude the 1px blank space margin when describing the region of the texture
                            // that actually represents the glyph.
                            const margin = 1;
                            glyph_atlas_region.x += margin;
                            glyph_atlas_region.y += margin;
                            glyph_atlas_region.width -= margin * 2;
                            glyph_atlas_region.height -= margin * 2;
                            region.value_ptr.* = glyph_atlas_region;
                        } else {
                            // whitespace
                            region.value_ptr.* = gfx.Atlas.Region{
                                .width = 0,
                                .height = 0,
                                .x = 0,
                                .y = 0,
                            };
                        }
                    }

                    const r = region.value_ptr.*;
                    const size = vec2(@floatFromInt(r.width), @floatFromInt(r.height));
                    try built_text.glyphs.append(allocator, .{
                        .pos = vec2(
                            origin_x + glyph.offset.x(),
                            origin_y - (size.y() - glyph.offset.y()),
                        ).divScalar(px_density),
                        .size = size.divScalar(px_density),
                        .text_index = num_texts,
                        .uv_pos = vec2(@floatFromInt(r.x), @floatFromInt(r.y)),
                    });
                    origin_x += glyph.advance.x();
                }
            }
            // Update the text entity's built form
            try text.set(id, .built, built_text);
            // TODO(text): see below
            // try text.remove(id, .dirty);
            try removes.append(allocator, id);

            // Add to the entire set of glyphs for this pipeline
            try glyphs.appendSlice(allocator, built_text.glyphs.items);
            num_texts += 1;
        }

        // TODO(important): removing components within an iter() currently produces undefined behavior
        // (entity may exist in current iteration, plus a future iteration as the iterator moves
        // on to the next archetype where the entity is now located.)
        for (removes.items) |remove_id| {
            try text.remove(remove_id, .dirty);
        }
    }

    // Every pipeline update, we copy updated glyph and text buffers to the GPU.
    try text_pipeline.set(pipeline_id, .num_texts, num_texts);
    try text_pipeline.set(pipeline_id, .num_glyphs, @intCast(glyphs.items.len));
    if (glyphs.items.len > 0) encoder.writeBuffer(built.glyphs, 0, glyphs.items);
    if (num_texts > 0) {
        encoder.writeBuffer(built.transforms, 0, gfx.TextPipeline.cp_transforms[0..num_texts]);
    }

    if (texture_update) {
        // TODO(text): do not assume texture's data_layout and img_size here, instead get it from
        // somewhere known to be matching the actual texture.
        //
        // TODO(text): allow users to specify RGBA32 or other pixel formats
        const img_size = gpu.Extent3D{ .width = 1024, .height = 1024 };
        const data_layout = gpu.Texture.DataLayout{
            .bytes_per_row = @as(u32, @intCast(img_size.width * 4)),
            .rows_per_image = @as(u32, @intCast(img_size.height)),
        };
        core.state().queue.writeTexture(
            &.{ .texture = built.texture },
            &data_layout,
            &img_size,
            built.texture_atlas.data,
        );
    }

    if (num_texts > 0 or glyphs.items.len > 0) {
        var command = encoder.finish(null);
        defer command.release();
        core.state().queue.submit(&[_]*gpu.CommandBuffer{command});
    }
}
