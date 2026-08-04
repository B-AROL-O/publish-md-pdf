-- file: mermaid-filter.lua
-- luacheck: globals CodeBlock
-- luacheck: read_globals pandoc
--
-- Pandoc Lua filter: renders fenced ```mermaid code blocks to PNG images via
-- mermaid-cli (mmdc), so publish-md-pdf.sh embeds the actual diagram instead
-- of the literal diagram source as a code block. PNG rather than SVG: mmdc's
-- SVG output places diagram labels in <foreignObject> (embedded XHTML), which
-- WeasyPrint's SVG renderer doesn't support, leaving every label blank; PNG
-- goes through Chromium's own compositing, so labels always render.
--
-- Controlled by two environment variables, both set by publish-md-pdf.sh
-- only when `mmdc` is on PATH:
--   PUBLISH_MD_PDF_MERMAID_TMPDIR            directory to write rendered .png files into
--   PUBLISH_MD_PDF_MERMAID_PUPPETEER_CONFIG  --puppeteerConfigFile passed to mmdc
--
-- If PUBLISH_MD_PDF_MERMAID_TMPDIR isn't set (mmdc unavailable), every
-- CodeBlock is left untouched, so behavior falls back to the pre-existing
-- "rendered as code" output. A block that fails to render (bad diagram
-- syntax, mmdc crash, ...) is also left untouched, with a warning on stderr.

local tmp_dir = os.getenv("PUBLISH_MD_PDF_MERMAID_TMPDIR")
local puppeteer_config = os.getenv("PUBLISH_MD_PDF_MERMAID_PUPPETEER_CONFIG")
local diagram_count = 0

local function has_class(block, class)
	for _, c in ipairs(block.classes) do
		if c == class then
			return true
		end
	end
	return false
end

function CodeBlock(block)
	if not tmp_dir or not has_class(block, "mermaid") then
		return nil
	end

	diagram_count = diagram_count + 1
	local base = tmp_dir .. "/mermaid-" .. diagram_count
	local mmd_file = base .. ".mmd"
	local png_file = base .. ".png"
	local log_file = base .. ".log"

	local input = io.open(mmd_file, "w")
	input:write(block.text)
	input:close()

	local cmd = string.format(
		"mmdc -i '%s' -o '%s' -b transparent --scale 2 --puppeteerConfigFile '%s' >'%s' 2>&1",
		mmd_file,
		png_file,
		puppeteer_config,
		log_file
	)
	local ok = os.execute(cmd)
	local png = io.open(png_file, "r")

	if ok and png then
		png:close()
		return pandoc.Para({ pandoc.Image({}, png_file, "Mermaid diagram") })
	end

	if png then
		png:close()
	end
	io.stderr:write(
		"WARNING: failed to render mermaid diagram #"
			.. diagram_count
			.. " (see "
			.. log_file
			.. "); rendering it as a code block instead\n"
	)
	return nil
end

-- EOF
