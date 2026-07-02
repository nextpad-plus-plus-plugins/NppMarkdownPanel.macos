/*
 * NppMarkdownPanel — macOS port
 *
 * Real-time Markdown preview panel for Notepad++ macOS.
 * Uses WKWebView with marked.js + highlight.js for rendering.
 * Images with relative paths resolve natively via WKWebView's baseURL.
 *
 * Original Windows plugin by Jens Wollgarten (GPLv2)
 * macOS port: single-file Objective-C++ implementation
 */

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <string>
#include <cstring>
#include <dlfcn.h>
#include <dispatch/dispatch.h>

// ═══════════════════════════════════════════════════════════════════════════
//  Constants
// ═══════════════════════════════════════════════════════════════════════════

static const char *PLUGIN_NAME = "Markdown Panel";
static const int NB_FUNC = 8;
static FuncItem funcItem[NB_FUNC];
static NppData nppData;

static const int RENDER_DEBOUNCE_MS = 400;

// ═══════════════════════════════════════════════════════════════════════════
//  Settings
// ═══════════════════════════════════════════════════════════════════════════

struct MarkdownSettings {
    int zoomLevel = 100;
    bool autoShowPanel = false;
    bool syncWithCaret = true;
    bool syncWithFirstVisibleLine = true;
    bool allowAllExtensions = false;
    std::string supportedExtensions = "md,mkd,mdwn,mdown,mdtxt,markdown,mmd";
    bool enableMermaid = false;
    bool enableSquared = false;              // render mermaid flowcharts in the "squared" style
    std::string squaredTheme = "boardroom";  // boardroom | linen | blueprint
};

static MarkdownSettings sSettings;

// ═══════════════════════════════════════════════════════════════════════════
//  Plugin state
// ═══════════════════════════════════════════════════════════════════════════

// Content view — the NSView we register with the host via
// NPPM_DMM_REGISTERPANEL. It owns the WKWebView; it lives either inside
// the host's SidePanelHost (docked) or inside g_floatingPanel.contentView
// (floating fallback for older hosts without the docking API).
static NSView       *sContentView  = nil;
static WKWebView    *sWebView      = nil;

// Docking state. Exactly one of these is active after first show:
//   g_panelHandle > 0  → host accepted NPPM_DMM_REGISTERPANEL; docked path
//   g_floatingPanel    → host doesn't support docking; NSPanel fallback
static uint64_t      g_panelHandle  = 0;
static NSPanel      *g_floatingPanel = nil;

static bool sPanelVisible = false;
static bool sTemplateLoaded = false;
// True only after the WKWebView finishes loading the HTML template (so the
// renderMarkdown() JS + marked.js/highlight.js are available). Renders are
// gated on this and flushed from -didFinishNavigation: — a fixed dispatch_after
// delay raced the (slower) cold WebKit start on Tahoe, dropping the first render
// and leaving the placeholder until the panel was closed/reopened.
static bool sWebViewReady = false;
static std::string sLastRenderedText;
static std::string sCurrentFilePath;
static std::string sCurrentTempHtmlPath; // Track temp file for cleanup
static dispatch_block_t sPendingRender = nil;
static std::string sResourcesDir;
static std::string sFullTemplate; // HTML template with inlined JS/CSS

// Forward declarations
static void togglePanel();
static void syncWithCaretCmd();
static void syncWithFirstVisibleLineCmd();
static void showSettingsCmd();
static void showHelpCmd();
static void showAboutCmd();
static void exportToHtmlCmd();
static void renderMarkdownDirect();
static void renderMarkdownDeferred();
static void ensureContentView();
static NSPanel *ensureFloatingPanel();
static BOOL markdownPanelIsShown();

// ═══════════════════════════════════════════════════════════════════════════
//  Helpers
// ═══════════════════════════════════════════════════════════════════════════

static NppHandle getCurScintilla() {
    int which = -1;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 0) ? nppData._scintillaMainHandle : nppData._scintillaSecondHandle;
}

static intptr_t sci(NppHandle h, uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(h, msg, w, l);
}

static intptr_t npp(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(nppData._nppHandle, msg, w, l);
}

static std::string getCurrentFilePath() {
    char buf[4096] = {0};
    npp(NPPM_GETFULLCURRENTPATH, sizeof(buf) - 1, (intptr_t)buf);
    return std::string(buf);
}

static std::string getCurrentExtension() {
    char buf[256] = {0};
    npp(NPPM_GETEXTPART, sizeof(buf) - 1, (intptr_t)buf);
    return std::string(buf);
}

static bool isSupportedExtension() {
    if (sSettings.allowAllExtensions) return true;
    std::string ext = getCurrentExtension();
    if (ext.empty()) return false;
    // Remove leading dot
    if (ext[0] == '.') ext = ext.substr(1);
    // Lowercase
    for (auto &c : ext) c = tolower(c);
    // Check against comma-separated list
    std::string exts = sSettings.supportedExtensions;
    for (auto &c : exts) c = tolower(c);
    size_t pos = 0;
    while (pos < exts.size()) {
        size_t comma = exts.find(',', pos);
        if (comma == std::string::npos) comma = exts.size();
        std::string candidate = exts.substr(pos, comma - pos);
        // Trim whitespace
        while (!candidate.empty() && candidate.front() == ' ') candidate.erase(candidate.begin());
        while (!candidate.empty() && candidate.back() == ' ') candidate.pop_back();
        if (candidate == ext) return true;
        pos = comma + 1;
    }
    return false;
}

// ═══════════════════════════════════════════════════════════════════════════
//  Resource loading
// ═══════════════════════════════════════════════════════════════════════════

static std::string findResourcesDir() {
    Dl_info info;
    if (dladdr((void *)&findResourcesDir, &info) && info.dli_fname) {
        std::string dylibPath(info.dli_fname);
        size_t lastSlash = dylibPath.rfind('/');
        if (lastSlash != std::string::npos) {
            return dylibPath.substr(0, lastSlash) + "/resources";
        }
    }
    return "";
}

static std::string readFileToString(const std::string &path) {
    @autoreleasepool {
        NSData *data = [NSData dataWithContentsOfFile:
            [NSString stringWithUTF8String:path.c_str()]];
        if (!data) return "";
        return std::string((const char *)[data bytes], [data length]);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  HTML template composition
// ═══════════════════════════════════════════════════════════════════════════

static const char *kGitHubMarkdownCSS = R"CSS(
/* GitHub-flavored Markdown CSS — minimal, supports light + dark */
:root {
  --color-fg: #1f2328;
  --color-bg: #ffffff;
  --color-border: #d0d7de;
  --color-code-bg: #f6f8fa;
  --color-blockquote: #59636e;
  --color-link: #0969da;
  --color-heading-border: #d8dee4;
}
@media (prefers-color-scheme: dark) {
  :root {
    --color-fg: #e6edf3;
    --color-bg: #0d1117;
    --color-border: #30363d;
    --color-code-bg: #161b22;
    --color-blockquote: #8b949e;
    --color-link: #58a6ff;
    --color-heading-border: #21262d;
  }
}
* { box-sizing: border-box; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif;
  font-size: 16px;
  line-height: 1.6;
  color: var(--color-fg);
  background: var(--color-bg);
  max-width: 980px;
  margin: 0 auto;
  padding: 20px 32px 48px;
  word-wrap: break-word;
}
h1, h2, h3, h4, h5, h6 { margin-top: 24px; margin-bottom: 16px; font-weight: 600; line-height: 1.25; }
h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid var(--color-heading-border); }
h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid var(--color-heading-border); }
h3 { font-size: 1.25em; }
h4 { font-size: 1em; }
h5 { font-size: 0.875em; }
h6 { font-size: 0.85em; color: var(--color-blockquote); }
p { margin-top: 0; margin-bottom: 16px; }
a { color: var(--color-link); text-decoration: none; }
a:hover { text-decoration: underline; }
img { max-width: 100%; height: auto; display: block; margin: 16px 0; border-radius: 6px; }
code {
  font-family: 'SF Mono', 'Menlo', 'Monaco', 'Courier New', monospace;
  font-size: 85%;
  padding: 0.2em 0.4em;
  background: var(--color-code-bg);
  border-radius: 6px;
}
pre {
  padding: 16px;
  overflow-x: auto;
  font-size: 85%;
  line-height: 1.45;
  background: var(--color-code-bg);
  border-radius: 6px;
  margin-bottom: 16px;
}
pre code { padding: 0; background: transparent; font-size: 100%; }
blockquote {
  margin: 0 0 16px;
  padding: 0 1em;
  color: var(--color-blockquote);
  border-left: 0.25em solid var(--color-border);
}
table { border-collapse: collapse; width: 100%; margin-bottom: 16px; }
th, td { padding: 6px 13px; border: 1px solid var(--color-border); }
th { font-weight: 600; background: var(--color-code-bg); }
tr:nth-child(2n) { background: var(--color-code-bg); }
hr { height: 0.25em; padding: 0; margin: 24px 0; background: var(--color-border); border: 0; border-radius: 2px; }
ul, ol { padding-left: 2em; margin-bottom: 16px; }
li + li { margin-top: 0.25em; }
input[type="checkbox"] { margin-right: 0.5em; }
/* YAML frontmatter displayed as code */
.frontmatter { background: var(--color-code-bg); padding: 12px 16px; border-radius: 6px; margin-bottom: 24px; font-size: 85%; font-family: monospace; color: var(--color-blockquote); border-left: 4px solid var(--color-border); white-space: pre-wrap; }
/* In-document search highlight — applied by highlightMatches() below */
mark.npp-find { background: #ffeb3b; color: #000; padding: 0 2px; border-radius: 2px; box-shadow: 0 0 0 1px rgba(0,0,0,0.1); }
mark.npp-find.current { background: #ff9800; box-shadow: 0 0 0 2px rgba(255,152,0,0.35); }
@media (prefers-color-scheme: dark) {
  mark.npp-find { background: #ffd54f; color: #000; }
  mark.npp-find.current { background: #ffb300; }
}
)CSS";

// Longest common ancestor directory of two absolute paths — used to scope the
// WKWebView's file read-access so a file:// preview page (written next to the
// user's markdown) can also reach the plugin's resources/squared engine dir.
static NSString *commonAncestorDir(NSString *a, NSString *b) {
    NSArray<NSString *> *pa = [a pathComponents], *pb = [b pathComponents];
    NSMutableArray<NSString *> *common = [NSMutableArray array];
    NSUInteger n = MIN(pa.count, pb.count);
    for (NSUInteger i = 0; i < n; i++) {
        if ([pa[i] isEqualToString:pb[i]]) [common addObject:pa[i]]; else break;
    }
    NSString *p = common.count ? [NSString pathWithComponents:common] : @"/";
    return p.length ? p : @"/";
}

static void buildTemplate() {
    @autoreleasepool {
        std::string markedJS = readFileToString(sResourcesDir + "/marked.min.js");
        std::string hljsJS = readFileToString(sResourcesDir + "/highlight.min.js");
        std::string hljsLightCSS = readFileToString(sResourcesDir + "/hljs-github.css");
        std::string hljsDarkCSS = readFileToString(sResourcesDir + "/hljs-github-dark.css");

        if (markedJS.empty()) {
            NSLog(@"[MarkdownPanel] ERROR: marked.min.js not found in %s", sResourcesDir.c_str());
            return;
        }

        // Check for optional mermaid
        std::string mermaidJS;
        if (sSettings.enableMermaid) {
            mermaidJS = readFileToString(sResourcesDir + "/mermaid.min.js");
        }

        std::string html = "<!DOCTYPE html>\n<html><head>\n<meta charset=\"utf-8\">\n";
        html += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n";

        // CSS
        html += "<style>\n";
        html += kGitHubMarkdownCSS;
        html += "\n</style>\n";
        // highlight.js light CSS (default)
        html += "<style media=\"(prefers-color-scheme: light)\">\n" + hljsLightCSS + "\n</style>\n";
        html += "<style media=\"(prefers-color-scheme: dark)\">\n" + hljsDarkCSS + "\n</style>\n";

        // Zoom
        html += "<style>body { zoom: " + std::to_string(sSettings.zoomLevel) + "%; }</style>\n";
        html += "<style>.squared-diagram{margin:16px 0;} .squared-diagram svg{max-width:100%;height:auto;}"
                " pre.squared-pending{background:transparent;border:none;padding:6px 0;}"
                " pre.squared-pending code{display:none;}"
                " pre.squared-pending::after{content:\"Rendering diagram\\2026\";color:#888;font-style:italic;}</style>\n";

        // JS libraries
        html += "<script>\n" + markedJS + "\n</script>\n";
        if (!hljsJS.empty()) {
            html += "<script>\n" + hljsJS + "\n</script>\n";
        }
        if (!mermaidJS.empty()) {
            html += "<script>\n" + mermaidJS + "\n</script>\n";
        }

        // The "squared" diagram engine, loaded as a file:// ES module from the plugin
        // resources (no network). The classic flag script runs synchronously; the
        // module script defers until after the app JS defines window.renderDiagrams(),
        // then renders any current diagram blocks.
        if (sSettings.enableSquared) {
            // Load the engine as a file:// module from the plugin resources (no network).
            // NSURL handles percent-encoding of the path (e.g. the space in "Application
            // Support"). squared.js's own imports + its Web Worker resolve relative to
            // this file:// URL, so they stay same-origin with the file:// preview page.
            NSString *jsPath = [NSString stringWithUTF8String:(sResourcesDir + "/squared/squared.js").c_str()];
            NSString *jsURL  = [[NSURL fileURLWithPath:jsPath] absoluteString];
            html += "<script>window.__squaredIntended=true;window.__squaredTheme='"
                  + sSettings.squaredTheme + "';</script>\n";
            html += "<script type=\"module\">\n";
            html += "try{\n";
            html += "  const m = await import('" + std::string([jsURL UTF8String]) + "');\n";
            html += "  window.renderSquared = m.renderSquared;\n";
            html += "  if (m.initSquared) m.initSquared();\n";
            html += "  if (window.renderDiagrams) window.renderDiagrams();\n";
            html += "}catch(e){ console.error('[squared] engine load failed', e); }\n";
            html += "</script>\n";
        }

        // Application JS
        html += R"HTML(
<script>
// Diagram rendering. Targets inline ```mermaid code blocks
// (pre code.language-mermaid) — the same blocks mermaid uses — so it works for
// diagrams inlined in .md files AND standalone .mmd files (wrapped natively).
// When "squared" is enabled it renders flowcharts in the squared style (async, via a
// Web Worker; non-flowcharts fall back to mermaid inside the engine). Otherwise
// it uses the classic mermaid path. Re-invoked when the squared engine loads.
window.renderDiagrams = function() {
  var blocks = document.querySelectorAll('pre code.language-mermaid');
  if (!blocks.length) return;
  if (window.__squaredIntended) {
    var ready = (typeof window.renderSquared === 'function');
    blocks.forEach(function(el) {
      if (el.getAttribute('data-sq')) return;              // process each block once
      var pre = el.parentNode, src = el.textContent;
      pre.classList.add('squared-pending');                // hide raw source immediately (no flash)
      if (!ready) return;                                  // engine still loading; stays hidden, re-runs on load
      el.setAttribute('data-sq', '1');
      window.renderSquared(src, { theme: window.__squaredTheme || 'boardroom' }).then(function(res) {
        if (res && res.ok && res.svg && pre.parentNode) {
          var wrap = document.createElement('div');
          wrap.className = 'squared-diagram';
          if (pre.id) wrap.id = pre.id;                    // keep block id for scroll sync
          wrap.innerHTML = res.svg;
          pre.parentNode.replaceChild(wrap, pre);
        } else {
          pre.classList.remove('squared-pending');         // render failed → reveal the source
        }
      }).catch(function(e) { console.error('[squared] render', e); pre.classList.remove('squared-pending'); });
    });
  } else if (typeof mermaid !== 'undefined') {
    blocks.forEach(function(el) {
      var pre = el.parentNode;
      pre.classList.add('mermaid');
      pre.innerHTML = el.textContent;
    });
    try { mermaid.run({ querySelector: '.mermaid' }); } catch (e) {}
  }
};

// Render function called from native code.
// Uses marked.js defaults for ALL rendering (no custom renderer overrides
// that might break across marked.js versions), then post-processes the HTML
// to add block IDs for scroll sync and apply syntax highlighting.
function renderMarkdown(md) {
  // Handle YAML frontmatter
  var content = md;
  var frontmatter = '';
  if (md.startsWith('---\n') || md.startsWith('---\r\n')) {
    var endIdx = md.indexOf('\n---', 3);
    if (endIdx === -1) endIdx = md.indexOf('\r\n---', 3);
    if (endIdx > 0) {
      var fmEnd = md.indexOf('\n', endIdx + 1);
      if (fmEnd === -1) fmEnd = md.length;
      frontmatter = md.substring(4, endIdx).trim();
      content = md.substring(fmEnd + 1);
    }
  }

  var html = '';
  if (frontmatter) {
    html += '<div class="frontmatter">' +
      frontmatter.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;') +
      '</div>\n';
  }

  // Render with marked.js defaults (handles images, code, tables, etc.)
  html += marked.parse(content, {gfm: true, breaks: false});

  // Post-process: add sequential IDs to block elements for scroll sync
  var blockIdx = 0;
  html = html.replace(/<(h[1-6]|p|pre|ul|ol|table|blockquote|hr)([\s>])/g,
    function(match, tag, after) {
      return '<' + tag + ' id="block-' + (blockIdx++) + '"' + after;
    });

  document.getElementById('content').innerHTML = html;

  // Build the source-line → block-id map used by scrollToLine() for
  // line-accurate forward scroll sync. The post-process regex above
  // assigns block-N ids in DOM order; marked.lexer walks the source
  // in the same order, so the indices match by construction. We
  // validate that count just below — if they ever drift (raw <html>
  // tokens whose first tag isn't in the regex's allowlist, etc.) we
  // clear the map so scrollToLine() falls back to proportional math.
  var newBlockMap = _buildBlockMap(md, content);
  var actualBlockCount = document.querySelectorAll('[id^="block-"]').length;
  if (newBlockMap.length === actualBlockCount && actualBlockCount > 0) {
    window._blockMap = newBlockMap;
  } else {
    if (newBlockMap.length !== actualBlockCount) {
      console.warn('[NppMarkdownPanel] blockMap/DOM mismatch (' +
        newBlockMap.length + ' vs ' + actualBlockCount +
        ') — falling back to proportional');
    }
    window._blockMap = [];
  }

  // Syntax highlighting: let highlight.js find and process all code blocks
  if (typeof hljs !== 'undefined') {
    document.querySelectorAll('pre code').forEach(function(el) {
      hljs.highlightElement(el);
    });
  }

  // Diagrams: "squared" style when enabled, else mermaid (see window.renderDiagrams).
  if (window.renderDiagrams) window.renderDiagrams();

  window._totalLines = md.split('\n').length;

  // Re-apply the search highlight after a re-render so the selection
  // survives typing in the editor. Native code updates window._searchQuery
  // via highlightMatches(); if it's non-empty we run the highlighter again.
  if (window._searchQuery) {
    highlightMatches(window._searchQuery);
  }
}

// ───────────────────── In-document search ─────────────────────
// Wrap every case-insensitive match of `query` in <mark class="npp-find">
// and scroll the first hit into view. Called natively on every keystroke
// (after a 120ms debounce) and again after each re-render.
//
// Implementation uses a TreeWalker over TEXT nodes, skipping anything
// inside <script>/<style>/<pre><code> so we don't mangle highlighted
// source blocks or break highlight.js output. Regex metachars in the
// query are escaped so the user can search for literal characters like
// "." or "(".
window._searchQuery = '';
function _escRegex(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

function _clearHighlights() {
  var marks = document.querySelectorAll('mark.npp-find');
  marks.forEach(function(m) {
    var parent = m.parentNode;
    if (!parent) return;
    while (m.firstChild) parent.insertBefore(m.firstChild, m);
    parent.removeChild(m);
    parent.normalize();
  });
}

function highlightMatches(query) {
  _clearHighlights();
  window._searchQuery = query || '';
  if (!query) return 0;

  var re = new RegExp(_escRegex(query), 'gi');
  var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
    acceptNode: function(node) {
      if (!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
      var p = node.parentElement;
      while (p) {
        var tag = p.tagName;
        if (tag === 'SCRIPT' || tag === 'STYLE') return NodeFilter.FILTER_REJECT;
        // Allow highlighting inside <code> / <pre> but skip if that's already
        // inside a hljs-processed span chain — we'd break the coloring.
        if (p.classList && p.classList.contains('hljs')) return NodeFilter.FILTER_REJECT;
        p = p.parentElement;
      }
      return NodeFilter.FILTER_ACCEPT;
    }
  });

  // Collect first so we don't mutate mid-walk.
  var targets = [];
  var n;
  while ((n = walker.nextNode())) {
    if (re.test(n.nodeValue)) targets.push(n);
    re.lastIndex = 0;
  }

  var count = 0;
  targets.forEach(function(node) {
    var text = node.nodeValue;
    var frag = document.createDocumentFragment();
    var lastIdx = 0;
    var m;
    re.lastIndex = 0;
    while ((m = re.exec(text))) {
      if (m.index > lastIdx) {
        frag.appendChild(document.createTextNode(text.slice(lastIdx, m.index)));
      }
      var mark = document.createElement('mark');
      mark.className = 'npp-find';
      mark.textContent = m[0];
      frag.appendChild(mark);
      lastIdx = re.lastIndex;
      count++;
      // Guard against zero-width match infinite loop (shouldn't happen
      // with escaped regex, but defend anyway).
      if (m.index === re.lastIndex) re.lastIndex++;
    }
    if (lastIdx < text.length) {
      frag.appendChild(document.createTextNode(text.slice(lastIdx)));
    }
    if (node.parentNode) node.parentNode.replaceChild(frag, node);
  });

  // Scroll the first hit to the middle of the viewport, non-smooth because
  // typists may be iterating and smooth scroll queues multiple animations.
  var first = document.querySelector('mark.npp-find');
  if (first) {
    first.classList.add('current');
    first.scrollIntoView({block: 'center', inline: 'nearest'});
  }
  return count;
}

// Scroll sync: block-level when the source-line/block-id map is
// available, proportional fallback otherwise. The block-level path
// gives line-accurate alignment even on documents with mixed block
// heights (a tall H1 next to compact code fences next to long
// paragraphs); the proportional path is the original implementation
// and is used as a defensive fallback when the lexer/post-process
// counts disagree.
window._blockMap = [];

// Walk marked's token tree to build [{line, id}, ...] entries that
// match the post-process regex's block-N ids one-for-one. The
// regex matches every <h1-6|p|pre|ul|ol|table|blockquote|hr> opening
// tag in DOM order; the walker emits one entry per token that
// produces such a tag. Two cases that aren't immediately obvious
// from the top-level token list and need recursion:
//
//   1) Loose lists (`tok.type === 'list' && tok.loose === true`).
//      Each item's content is wrapped in <p> in the rendered HTML
//      — that <p> matches the regex and gets a block-N id. The
//      child token inside a loose item is usually a 'text' token
//      (not 'paragraph'), so we treat it specially. Items with
//      multiple block children (e.g. a paragraph followed by a
//      code fence) get one entry per child.
//
//   2) Blockquotes. Their child tokens render with their own tags
//      (<p>, <h*>, <pre>, etc.) and each matches the regex.
//
// Without the recursion, blockMap is ~21 short on a 1300-line file
// with several loose lists; the validation gate then clears the
// map and scroll-sync falls back to proportional, defeating the
// whole point of this code.
//
// Returns [] if the lexer throws.
function _buildBlockMap(md, content) {
  var prefixLen = md.length - content.length;
  var contentStartLine = 0;
  if (prefixLen > 0) {
    contentStartLine = (md.substring(0, prefixLen).match(/\n/g) || []).length;
  }

  var blockMap = [];
  var blockIdx = 0;
  var tokens;
  try {
    tokens = marked.lexer(content);
  } catch (e) {
    return [];
  }

  // Token types whose top-level rendering produces a regex-matching tag.
  var BLOCK_TYPES = {
    heading: 1, paragraph: 1, code: 1, list: 1,
    table: 1, blockquote: 1, hr: 1
  };

  function rawNewlines(tok) {
    return (tok && tok.raw && tok.raw.match(/\n/g))
             ? tok.raw.match(/\n/g).length : 0;
  }

  function walk(toks, lineCursor, insideLooseListItem) {
    if (!toks) return;
    for (var i = 0; i < toks.length; i++) {
      var tok = toks[i];
      var lines = rawNewlines(tok);
      var startLine = lineCursor;

      if (tok.type === 'space' || tok.type === 'def') {
        lineCursor += lines;
        continue;
      }

      if (BLOCK_TYPES[tok.type]) {
        blockMap.push({ line: startLine, id: 'block-' + blockIdx });
        blockIdx++;
      } else if (insideLooseListItem && tok.type === 'text') {
        // Loose-list items wrap their first text token in a <p> in
        // the DOM, even though marked emits a 'text' token rather
        // than 'paragraph' for them.
        blockMap.push({ line: startLine, id: 'block-' + blockIdx });
        blockIdx++;
      }

      // Recurse for containers whose children produce regex-matching tags.
      if (tok.type === 'blockquote' && tok.tokens) {
        walk(tok.tokens, startLine, false);
      }
      if (tok.type === 'list' && tok.loose && tok.items) {
        var itemLineCursor = startLine;
        for (var j = 0; j < tok.items.length; j++) {
          var item = tok.items[j];
          if (item.tokens) walk(item.tokens, itemLineCursor, true);
          itemLineCursor += rawNewlines(item);
        }
      }

      lineCursor += lines;
    }
  }

  walk(tokens, contentStartLine, false);
  return blockMap;
}

// Compute the target Y pixel for a given source line using the
// blockMap. Returns a clamped value in [0, maxScroll]. Interpolates
// between adjacent blocks so caret movement through a multi-line
// block tracks smoothly instead of snapping at block boundaries.
function _resolveBlockTargetY(lineNo, bm, maxScroll) {
  // Binary search for the largest entry with line ≤ lineNo.
  var lo = 0, hi = bm.length - 1, k = -1;
  while (lo <= hi) {
    var mid = (lo + hi) >> 1;
    if (bm[mid].line <= lineNo) { k = mid; lo = mid + 1; }
    else                         { hi = mid - 1; }
  }
  if (k < 0) return 0;   // caret is before the first mapped block
                          // (e.g. inside front matter, which has no
                          // entry today); top of preview is the
                          // safest target.

  var blockEl = document.getElementById(bm[k].id);
  if (!blockEl) return 0;

  var startY = blockEl.offsetTop;

  // Interpolate between this block's top and the next block's top
  // (or the document end for the last block) using the fraction of
  // source lines between the blocks.
  if (k + 1 < bm.length) {
    var nextEl = document.getElementById(bm[k + 1].id);
    if (nextEl) {
      var lineSpan = bm[k + 1].line - bm[k].line;
      if (lineSpan > 0) {
        var t = Math.max(0, Math.min(1, (lineNo - bm[k].line) / lineSpan));
        startY = startY + t * (nextEl.offsetTop - startY);
      }
    }
  } else {
    // Last block — interpolate toward maxScroll so the caret on the
    // final source line lands at the bottom of the visible range.
    var lineSpan = (window._totalLines - 1) - bm[k].line;
    if (lineSpan > 0) {
      var t = Math.max(0, Math.min(1, (lineNo - bm[k].line) / lineSpan));
      startY = startY + t * (maxScroll - startY);
    }
  }

  return Math.max(0, Math.min(maxScroll, Math.round(startY)));
}

var _scrollTimer = null;
function scrollToLine(lineNo) {
  if (!window._totalLines || window._totalLines <= 1) return;
  // Cancel any pending scroll to avoid fighting fast caret movement.
  if (_scrollTimer) { clearTimeout(_scrollTimer); }
  _scrollTimer = setTimeout(function() {
    var maxScroll = Math.max(0,
      document.documentElement.scrollHeight - window.innerHeight);
    var targetY;
    var bm = window._blockMap || [];
    if (bm.length > 0) {
      targetY = _resolveBlockTargetY(lineNo, bm, maxScroll);
    } else {
      // Proportional fallback (original implementation): used when the
      // blockMap couldn't be built or its count disagreed with the DOM.
      var ratio = Math.max(0, Math.min(1, lineNo / (window._totalLines - 1)));
      targetY = Math.round(ratio * maxScroll);
    }
    window.scrollTo({ top: targetY, behavior: 'smooth' });
    _scrollTimer = null;
  }, 50);
}

// Scroll to top
function scrollToTop() {
  window.scrollTo({top: 0, behavior: 'smooth'});
}

// Initialize mermaid if available
if (typeof mermaid !== 'undefined') {
  mermaid.initialize({startOnLoad: false, theme: 'default'});
}
</script>
</head>
<body>
<div id="content"><p style="color: #888; font-style: italic;">Markdown preview will appear here...</p></div>
</body>
</html>
)HTML";

        sFullTemplate = html;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Settings persistence
// ═══════════════════════════════════════════════════════════════════════════

static std::string getConfigPath() {
    char buf[1024] = {};
    nppData._sendMessage(nppData._nppHandle, NPPM_GETPLUGINSCONFIGDIR,
                         (uintptr_t)sizeof(buf), (intptr_t)buf);
    NSString *dir;
    if (buf[0] != '\0') {
        dir = [NSString stringWithUTF8String:buf];
    } else {
        // Fallback only if the host returns empty (it does not on shipped
        // versions): the app-support base, NOT a legacy ~/.nextpad++ dot-folder.
        dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                   NSUserDomainMask, YES).firstObject
                   stringByAppendingPathComponent:@"Nextpad++/plugins/Config"];
    }
    return std::string([dir UTF8String]) + "/NppMarkdownPanel.json";
}

static void loadSettings() {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:getConfigPath().c_str()];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) return;
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!dict) return;

        NSNumber *v;
        NSString *s;
        if ((v = dict[@"zoomLevel"])) sSettings.zoomLevel = [v intValue];
        if ((v = dict[@"autoShowPanel"])) sSettings.autoShowPanel = [v boolValue];
        if ((v = dict[@"syncWithCaret"])) sSettings.syncWithCaret = [v boolValue];
        if ((v = dict[@"syncWithFirstVisibleLine"])) sSettings.syncWithFirstVisibleLine = [v boolValue];
        if ((v = dict[@"allowAllExtensions"])) sSettings.allowAllExtensions = [v boolValue];
        if ((s = dict[@"supportedExtensions"])) sSettings.supportedExtensions = [s UTF8String];
        if ((v = dict[@"enableMermaid"])) sSettings.enableMermaid = [v boolValue];
        if ((v = dict[@"enableSquared"])) sSettings.enableSquared = [v boolValue];
        if ((s = dict[@"squaredTheme"])) sSettings.squaredTheme = [s UTF8String];

        // Migration: ensure .mmd is in the supported extensions list
        {
            std::string exts = sSettings.supportedExtensions;
            std::string lower = exts;
            for (auto &c : lower) c = tolower(c);
            if (lower.find("mmd") == std::string::npos) {
                sSettings.supportedExtensions += ",mmd";
            }
        }

        // Migration: the two sync modes used to be mutually exclusive
        // (toggling one auto-disabled the other). After moving to
        // independent toggles, users upgrading from an older build
        // would have exactly one of the two enabled — meaning the
        // other trigger (click → caret-line, or wheel → first-visible
        // line) silently produced no preview update. If the saved
        // config has at least one enabled, force both on so the new
        // independent behavior is the default. Users who explicitly
        // disable one via the menu still get their choice persisted
        // on next save.
        if (sSettings.syncWithCaret || sSettings.syncWithFirstVisibleLine) {
            sSettings.syncWithCaret           = true;
            sSettings.syncWithFirstVisibleLine = true;
        }
    }
}

static void saveSettings() {
    @autoreleasepool {
        NSDictionary *dict = @{
            @"zoomLevel": @(sSettings.zoomLevel),
            @"autoShowPanel": @(sSettings.autoShowPanel),
            @"syncWithCaret": @(sSettings.syncWithCaret),
            @"syncWithFirstVisibleLine": @(sSettings.syncWithFirstVisibleLine),
            @"allowAllExtensions": @(sSettings.allowAllExtensions),
            @"supportedExtensions": @(sSettings.supportedExtensions.c_str()),
            @"enableMermaid": @(sSettings.enableMermaid),
            @"enableSquared": @(sSettings.enableSquared),
            @"squaredTheme": @(sSettings.squaredTheme.c_str()),
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                      options:NSJSONWritingPrettyPrinted error:nil];
        if (data) {
            [data writeToFile:[NSString stringWithUTF8String:getConfigPath().c_str()] atomically:YES];
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Toolbar-row helpers: search field delegate + panel-style button
// ═══════════════════════════════════════════════════════════════════════════

// Forward declaration — button knows how to reload its icon on dark-mode flip.
@class _NMPPanelButton;

// Panel-toolbar button matching the host's _FTPanelButton style
// (FolderTreePanel.mm): 16×16 bounds, NO border at rest, toolbar-blue fill +
// border on hover/press (fill skipped in dark mode), image drawn centered
// at intrinsic size. Icon comes from the plugin's bundled resources and
// swaps on light/dark appearance changes.
@interface _NMPPanelButton : NSButton {
    BOOL _hovering;
}
@property (nonatomic, copy) NSString *lightIconName;  // basename w/o .png (PNG icons)
@property (nonatomic, copy) NSString *darkIconName;
@property (nonatomic, copy) NSString *symbolName;     // SF Symbol name (overrides PNG when set)
@property (nonatomic, assign) BOOL     accentBlue;    // render the symbol with a blue (system) accent
- (void)reloadIcon;
@end

@implementation _NMPPanelButton

- (instancetype)init {
    self = [super init];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.bordered = NO;
        [self setButtonType:NSButtonTypeMomentaryChange];
        [self.widthAnchor  constraintEqualToConstant:16].active = YES;
        [self.heightAnchor constraintEqualToConstant:16].active = YES;
        NSTrackingArea *ta = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:(NSTrackingMouseEnteredAndExited |
                          NSTrackingActiveInActiveApp |
                          NSTrackingInVisibleRect)
                   owner:self userInfo:nil];
        [self addTrackingArea:ta];
    }
    return self;
}

- (void)mouseEntered:(NSEvent *)event { _hovering = YES;  [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)event  { _hovering = NO;   [self setNeedsDisplay:YES]; }

- (BOOL)_isDark {
    if (@available(macOS 10.14, *)) {
        NSAppearanceName match = [self.effectiveAppearance
            bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,
                                                 NSAppearanceNameDarkAqua]];
        return [match isEqualToString:NSAppearanceNameDarkAqua];
    }
    return NO;
}

- (void)reloadIcon {
    NSImage *img = nil;
    if (_symbolName.length) {
        // SF Symbol rendered into a fixed 12×12 image — uniform with the other icon
        // buttons so the hover highlight is a matching square. accentBlue → the
        // two-tone square.and.arrow.down look (dark glyph + blue enclosure).
        if (@available(macOS 11.0, *)) {
            NSImage *sym = [NSImage imageWithSystemSymbolName:_symbolName accessibilityDescription:nil];
            NSImageSymbolConfiguration *sizeCfg =
                [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular];
            BOOL twoTone = NO;
            if (_accentBlue) {
                if (@available(macOS 12.0, *)) {
                    NSImageSymbolConfiguration *pal = [NSImageSymbolConfiguration
                        configurationWithPaletteColors:@[[NSColor labelColor], [NSColor systemBlueColor]]];
                    NSImage *c = [sym imageWithSymbolConfiguration:[sizeCfg configurationByApplyingConfiguration:pal]];
                    if (c) { sym = c; twoTone = YES; }   // two colors — draw as-is
                }
            }
            if (!twoTone) { NSImage *c = [sym imageWithSymbolConfiguration:sizeCfg]; if (c) sym = c; }
            NSColor *flat = _accentBlue ? [NSColor systemBlueColor] : [NSColor labelColor];
            img = [NSImage imageWithSize:NSMakeSize(12, 12) flipped:NO drawingHandler:^BOOL(NSRect r) {
                [sym drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                       fraction:1.0 respectFlipped:YES hints:nil];
                if (!twoTone) { [flat set]; NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop); }
                return YES;
            }];
        }
    } else {
        NSString *name = [self _isDark] ? _darkIconName : _lightIconName;
        if (name.length) {
            // 11pt rendered size matches FolderTreePanel's kFTToolbarIconSize
            // — the image's own PNG is high-res; we down-render at 11pt.
            NSString *path = [NSString stringWithFormat:@"%s/%@.png", sResourcesDir.c_str(), name];
            img = [[NSImage alloc] initWithContentsOfFile:path];
            if (img) img.size = NSMakeSize(11, 11);
        }
    }
    if (img) self.image = img;
    [self setNeedsDisplay:YES];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self reloadIcon];
}

- (void)drawRect:(NSRect)dirtyRect {
    BOOL pressed = self.isHighlighted;
    BOOL active  = pressed || _hovering;
    BOOL isDark  = [self _isDark];

    if (active) {
        if (!isDark) {
            NSColor *bg = pressed
                ? [NSColor colorWithRed:0xCC/255.0 green:0xE8/255.0 blue:0xFF/255.0 alpha:1.0]
                : [NSColor colorWithRed:0xE5/255.0 green:0xF3/255.0 blue:0xFF/255.0 alpha:1.0];
            [bg setFill];
            NSRectFill(self.bounds);
        }
        NSColor *bdr = [NSColor colorWithRed:0xD0/255.0 green:0xEA/255.0 blue:0xFF/255.0 alpha:1.0];
        NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds, 0.5, 0.5)];
        border.lineWidth = 1.0;
        [bdr setStroke];
        [border stroke];
    }

    if (self.image) {
        NSSize isz = self.image.size;
        NSRect ir = NSMakeRect(NSMidX(self.bounds) - isz.width / 2.0,
                               NSMidY(self.bounds) - isz.height / 2.0,
                               isz.width, isz.height);
        [self.image drawInRect:ir
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver
                      fraction:1.0
                respectFlipped:YES
                         hints:nil];
    }
}

@end

// Search-field delegate: debounces keystrokes and re-runs the highlighter.
// Lives as a single static instance — all sessions share one delegate.
@interface _NMPSearchFieldDelegate : NSObject <NSTextFieldDelegate>
@end

// Static forward declarations for the two C functions the delegate calls.
static void markdownApplySearchQuery(NSString *query);
static void printMarkdownPreview();
static void refreshMarkdownPreview();
static void saveMarkdownAsPDF();
static void adjustPreviewZoom(int delta);

@implementation _NMPSearchFieldDelegate

- (void)controlTextDidChange:(NSNotification *)note {
    NSTextField *tf = note.object;
    markdownApplySearchQuery(tf.stringValue ?: @"");
}

// Cancel button in the field (Escape clears)
- (BOOL)control:(NSControl *)control textView:(NSTextView *)fieldEditor
     doCommandBySelector:(SEL)cmd {
    if (cmd == @selector(cancelOperation:)) {
        NSTextField *tf = (NSTextField *)control;
        if (tf.stringValue.length) {
            tf.stringValue = @"";
            markdownApplySearchQuery(@"");
            return YES;
        }
    }
    return NO;
}

// Print button forwards here — keeps the action receiver in ObjC while the
// actual work happens in a C function that has access to the static state
// (sWebView, etc.) without bridging.
+ (void)_doPrint    { printMarkdownPreview(); }
+ (void)_doSettings { showSettingsCmd(); }
+ (void)_doRefresh  { refreshMarkdownPreview(); }
+ (void)_doSavePDF  { saveMarkdownAsPDF(); }

@end

// Shared state the toolbar-row functions below read/write. Declared before
// the first use so markdownApplySearchQuery() compiles without a forward
// decl shuffle.
static _NMPSearchFieldDelegate *sSearchDelegate = nil;
static NSTextField             *sSearchField    = nil;
static _NMPPanelButton         *sPrintButton    = nil;
static _NMPPanelButton         *sSettingsButton = nil;
static _NMPPanelButton         *sRefreshButton  = nil;
static _NMPPanelButton         *sPdfButton      = nil;
static id                       sZoomKeyMonitor = nil;

// Latest search query, kept so we can reapply after every re-render. Non-
// empty only while the user has typed into the search field.
static std::string sCurrentSearchText;

// Debounce handle for keystroke → JS highlight propagation.
static dispatch_block_t sPendingSearch = nil;

// ─────────────────────────────────────────────────────────────────────────────
// JS-escape a plain string for safe embedding inside a JS single-quoted
// string literal. Escapes: backslash, single quote, CR, LF, paragraph &
// line separators (U+2028/U+2029 would otherwise end a JS line).
// ─────────────────────────────────────────────────────────────────────────────
static NSString *jsEscapeSingleQuote(NSString *s) {
    if (!s) return @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length)
                          options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) {
        if ([sub isEqualToString:@"\\"])      [out appendString:@"\\\\"];
        else if ([sub isEqualToString:@"'"])  [out appendString:@"\\'"];
        else if ([sub isEqualToString:@"\n"]) [out appendString:@"\\n"];
        else if ([sub isEqualToString:@"\r"]) [out appendString:@"\\r"];
        else if ([sub isEqualToString:@"\u2028"]) [out appendString:@"\\u2028"];
        else if ([sub isEqualToString:@"\u2029"]) [out appendString:@"\\u2029"];
        else                                  [out appendString:sub];
    }];
    return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// Debounced live search. Every keystroke cancels the pending dispatch and
// queues a fresh one 120ms later, so a fast typist doesn't pay per-key.
// Empty query clears the highlights in the WKWebView.
// ─────────────────────────────────────────────────────────────────────────────
static void markdownApplySearchQuery(NSString *query) {
    sCurrentSearchText = query ? std::string([query UTF8String]) : std::string();

    if (sPendingSearch) {
        dispatch_block_cancel(sPendingSearch);
        sPendingSearch = nil;
    }
    // Snapshot the query for the block — user may keep typing before fire.
    NSString *captured = [query copy] ?: @"";
    sPendingSearch = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{
        if (!sWebView) return;
        @autoreleasepool {
            NSString *escaped = jsEscapeSingleQuote(captured);
            NSString *js = [NSString stringWithFormat:
                @"if (typeof highlightMatches === 'function') highlightMatches('%@');",
                escaped];
            [sWebView evaluateJavaScript:js completionHandler:nil];
        }
        sPendingSearch = nil;
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), sPendingSearch);
}

// ─────────────────────────────────────────────────────────────────────────────
// Print: hand off to WKWebView's native print operation. Runs as a sheet
// on whichever window currently hosts sContentView (main app when docked,
// FloatingPanelWindow when popped out, g_floatingPanel as fallback).
// ─────────────────────────────────────────────────────────────────────────────
static void printMarkdownPreview() {
    if (!sWebView) return;
    NSWindow *host = sContentView.window ?: g_floatingPanel;
    if (!host) return;  // Nothing to attach a print sheet to

    @autoreleasepool {
        NSPrintInfo *info = [[NSPrintInfo sharedPrintInfo] copy];
        info.topMargin    = 36;
        info.bottomMargin = 36;
        info.leftMargin   = 36;
        info.rightMargin  = 36;
        info.horizontalPagination = NSPrintingPaginationModeAutomatic;
        info.verticalPagination   = NSPrintingPaginationModeAutomatic;

        NSPrintOperation *op = [sWebView printOperationWithPrintInfo:info];
        op.showsPrintPanel    = YES;
        op.showsProgressPanel = YES;
        op.jobTitle           = @"Markdown Preview";
        [op runOperationModalForWindow:host
                              delegate:nil
                        didRunSelector:NULL
                           contextInfo:NULL];
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  WKWebView panel
// ═══════════════════════════════════════════════════════════════════════════

@interface MarkdownNavigationDelegate : NSObject <WKNavigationDelegate>
@end

@implementation MarkdownNavigationDelegate
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    // Allow initial loads and JS-triggered navigations
    if (action.navigationType == WKNavigationTypeOther ||
        action.navigationType == WKNavigationTypeReload) {
        handler(WKNavigationActionPolicyAllow);
        return;
    }
    // Open external links in the default browser
    NSURL *url = action.request.URL;
    if (url && ([@"http" isEqualToString:url.scheme] || [@"https" isEqualToString:url.scheme])) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
    handler(WKNavigationActionPolicyCancel);
}

// The template HTML (with renderMarkdown() + marked.js/highlight.js) has
// finished loading — now it's safe to inject markdown. Flush the current
// document instead of relying on a fixed timer that can fire too early on a
// cold WebKit start (the Tahoe first-open race).
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    sWebViewReady = true;
    renderMarkdownDirect();
}

// Never leave the view permanently "not ready" if a load fails — allow later
// loads/renders to proceed rather than getting stuck on the placeholder.
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    sWebViewReady = true;
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    sWebViewReady = true;
}
@end

static MarkdownNavigationDelegate *sNavDelegate = nil;

// Build (once) the NSView that wraps the search/print toolbar row + the
// WKWebView. Used by both the docked path (registered via
// NPPM_DMM_REGISTERPANEL) and the floating fallback (installed as the
// NSPanel's contentView). Same NSView instance is reused — it moves
// between hosting windows without being rebuilt.
//
// Layout (matches FunctionListPanel.mm's search-row pattern):
//   [search field ▸ expandable] [print button 16×16]
//   ─────────────────────────────────────────────────
//   [WKWebView — fills the rest]
static void ensureContentView() {
    if (sContentView) return;

    @autoreleasepool {
        // Initial frame is only meaningful for the floating fallback — the
        // host sizes the view to the side-panel stack when docked. 500×700
        // matches the old NSPanel default so first-time floating users see
        // the same geometry as before.
        sContentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 700)];

        // ── Search field ───────────────────────────────────────────────
        sSearchField = [[NSTextField alloc] init];
        sSearchField.translatesAutoresizingMaskIntoConstraints = NO;
        sSearchField.placeholderString = @"Search in document...";
        sSearchField.font = [NSFont systemFontOfSize:11];
        sSearchField.bezelStyle = NSTextFieldRoundedBezel;
        [[sSearchField cell] setScrollable:YES];
        sSearchDelegate = [[_NMPSearchFieldDelegate alloc] init];
        sSearchField.delegate = sSearchDelegate;
        [sContentView addSubview:sSearchField];

        // ── Print button ───────────────────────────────────────────────
        sPrintButton = [[_NMPPanelButton alloc] init];
        sPrintButton.lightIconName = @"print_light";
        sPrintButton.darkIconName  = @"print_dark";
        sPrintButton.toolTip       = @"Print preview";
        sPrintButton.target        = [_NMPSearchFieldDelegate class];
        // Use a static dispatcher (class method on the delegate) so the
        // action lives in Objective-C even though the actual work is a
        // C function call. See +_doPrint below.
        sPrintButton.action        = @selector(_doPrint);
        [sPrintButton reloadIcon];
        [sContentView addSubview:sPrintButton];

        // ── Settings / Refresh / Save-PDF buttons (SF Symbols, print-icon size) ──
        sSettingsButton = [[_NMPPanelButton alloc] init];
        sSettingsButton.symbolName = @"gearshape";
        sSettingsButton.toolTip    = @"Settings";
        sSettingsButton.target     = [_NMPSearchFieldDelegate class];
        sSettingsButton.action     = @selector(_doSettings);
        [sSettingsButton reloadIcon];
        [sContentView addSubview:sSettingsButton];

        sRefreshButton = [[_NMPPanelButton alloc] init];
        sRefreshButton.symbolName = @"arrow.clockwise";
        sRefreshButton.toolTip    = @"Refresh preview";
        sRefreshButton.target     = [_NMPSearchFieldDelegate class];
        sRefreshButton.action     = @selector(_doRefresh);
        [sRefreshButton reloadIcon];
        [sContentView addSubview:sRefreshButton];

        sPdfButton = [[_NMPPanelButton alloc] init];
        sPdfButton.lightIconName = @"save_light";  // save/floppy icon (light + dark variants)
        sPdfButton.darkIconName  = @"save_dark";
        sPdfButton.toolTip       = @"Save as PDF";
        sPdfButton.target        = [_NMPSearchFieldDelegate class];
        sPdfButton.action        = @selector(_doSavePDF);
        [sPdfButton reloadIcon];
        [sContentView addSubview:sPdfButton];

        // ── WKWebView ──────────────────────────────────────────────────
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        config.defaultWebpagePreferences.allowsContentJavaScript = YES;
        // The "squared" engine loads as file:// ES modules + a file:// module Web Worker.
        // A Worker must be same-origin as the page (which is file://), so relax file-URL
        // access (KVC — the standard WKWebView keys for local preview content). This lets
        // the file:// preview import the engine from the plugin resources dir and lets the
        // engine spawn its file:// worker.
        @try { [config.preferences setValue:@YES forKey:@"allowFileAccessFromFileURLs"]; } @catch (id e) {}
        @try { [config setValue:@YES forKey:@"allowUniversalAccessFromFileURLs"]; } @catch (id e) {}

        sWebView = [[WKWebView alloc] initWithFrame:NSZeroRect
                                       configuration:config];
        sWebView.translatesAutoresizingMaskIntoConstraints = NO;
        // Allow Web Inspector (right-click → Inspect Element) to debug the
        // squared/mermaid render path. macOS 13.3+.
        if (@available(macOS 13.3, *)) { sWebView.inspectable = YES; }

        sNavDelegate = [[MarkdownNavigationDelegate alloc] init];
        sWebView.navigationDelegate = sNavDelegate;

        [sContentView addSubview:sWebView];

        // ── Constraints ────────────────────────────────────────────────
        [NSLayoutConstraint activateConstraints:@[
            // Search field: 4pt top gap, 6pt leading gutter, 6pt gap to
            // print button; 22pt tall (matches FunctionList row height).
            [sSearchField.topAnchor      constraintEqualToAnchor:sContentView.topAnchor constant:4],
            [sSearchField.leadingAnchor  constraintEqualToAnchor:sContentView.leadingAnchor constant:6],
            [sSearchField.trailingAnchor constraintEqualToAnchor:sSettingsButton.leadingAnchor constant:-8],
            [sSearchField.heightAnchor   constraintEqualToConstant:22],

            // Toolbar buttons (16×16 each), left→right: settings, refresh, save-PDF, print.
            [sSettingsButton.trailingAnchor constraintEqualToAnchor:sRefreshButton.leadingAnchor constant:-8],
            [sSettingsButton.centerYAnchor  constraintEqualToAnchor:sSearchField.centerYAnchor],
            [sRefreshButton.trailingAnchor  constraintEqualToAnchor:sPdfButton.leadingAnchor constant:-8],
            [sRefreshButton.centerYAnchor   constraintEqualToAnchor:sSearchField.centerYAnchor],
            [sPdfButton.trailingAnchor      constraintEqualToAnchor:sPrintButton.leadingAnchor constant:-8],
            [sPdfButton.centerYAnchor       constraintEqualToAnchor:sSearchField.centerYAnchor],
            [sPrintButton.trailingAnchor    constraintEqualToAnchor:sContentView.trailingAnchor constant:-6],
            [sPrintButton.centerYAnchor     constraintEqualToAnchor:sSearchField.centerYAnchor],

            // WebView fills below the toolbar row, flush to edges.
            [sWebView.topAnchor      constraintEqualToAnchor:sSearchField.bottomAnchor constant:4],
            [sWebView.leadingAnchor  constraintEqualToAnchor:sContentView.leadingAnchor],
            [sWebView.trailingAnchor constraintEqualToAnchor:sContentView.trailingAnchor],
            [sWebView.bottomAnchor   constraintEqualToAnchor:sContentView.bottomAnchor],
        ]];

        // Cmd +/- (and Cmd 0 to reset) zoom the preview live — only while the preview
        // WebView is focused, so the editor's own Cmd +/- zoom is never hijacked.
        if (!sZoomKeyMonitor) {
            sZoomKeyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                handler:^NSEvent *(NSEvent *e) {
                if (!(e.modifierFlags & NSEventModifierFlagCommand)) return e;
                if (!sWebView || !sPanelVisible) return e;
                NSWindow *w = sWebView.window;
                if (!w || w != [NSApp keyWindow]) return e;
                BOOL inPreview = NO;
                NSResponder *fr = w.firstResponder;
                if ([fr isKindOfClass:[NSView class]]) {
                    for (NSView *v = (NSView *)fr; v; v = v.superview) { if (v == sWebView) { inPreview = YES; break; } }
                }
                if (!inPreview) return e;
                NSString *ch = e.charactersIgnoringModifiers;
                if ([ch isEqualToString:@"="] || [ch isEqualToString:@"+"]) { adjustPreviewZoom(+10); return nil; }
                if ([ch isEqualToString:@"-"] || [ch isEqualToString:@"_"]) { adjustPreviewZoom(-10); return nil; }
                if ([ch isEqualToString:@"0"])                              { adjustPreviewZoom(100 - sSettings.zoomLevel); return nil; }
                return e;
            }];
        }
    }
}

// Build (lazily) the floating NSPanel used as the fallback when the host
// doesn't support NPPM_DMM_* docking. sContentView becomes the panel's
// content view. Close via the red traffic light is caught by an
// NSWindowWillCloseNotification observer scoped to this panel only —
// the docked path detects close via a runtime isShown check instead.
static NSPanel *ensureFloatingPanel() {
    if (g_floatingPanel) return g_floatingPanel;
    ensureContentView();

    @autoreleasepool {
        NSRect frame = NSMakeRect(100, 100, 500, 700);
        NSUInteger mask = NSWindowStyleMaskTitled    |
                          NSWindowStyleMaskClosable  |
                          NSWindowStyleMaskResizable |
                          NSWindowStyleMaskUtilityWindow;
        g_floatingPanel = [[NSPanel alloc] initWithContentRect:frame
                                                      styleMask:mask
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
        [g_floatingPanel setTitle:@"Markdown Panel"];
        [g_floatingPanel setFloatingPanel:NO];
        [g_floatingPanel setHidesOnDeactivate:NO];
        [g_floatingPanel setReleasedWhenClosed:NO];
        [g_floatingPanel setLevel:NSNormalWindowLevel];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowWillCloseNotification
                       object:g_floatingPanel
                        queue:nil
                   usingBlock:^(NSNotification *note) {
                       sPanelVisible = false;
                       nppData._sendMessage(nppData._nppHandle, NPPM_SETMENUITEMCHECK,
                                            (uintptr_t)funcItem[0]._cmdID, 0);
                   }];

        // Install sContentView to fill the NSPanel's content area.
        sContentView.frame = ((NSView *)g_floatingPanel.contentView).bounds;
        sContentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [g_floatingPanel.contentView addSubview:sContentView];

        // First-time placement: to the right of the main window, matching
        // its height — preserves the original pre-docking UX.
        NSWindow *mainWin = [NSApp mainWindow];
        if (mainWin) {
            NSRect mainFrame = mainWin.frame;
            NSRect panelFrame = g_floatingPanel.frame;
            panelFrame.origin.x = NSMaxX(mainFrame) + 4;
            panelFrame.origin.y = mainFrame.origin.y;
            panelFrame.size.height = mainFrame.size.height;
            [g_floatingPanel setFrame:panelFrame display:NO];
        }
    }
    return g_floatingPanel;
}

// Runtime check — is the preview currently rendered somewhere?
//   docked:   sContentView has a window AND a superview (i.e. it's in
//             the host's SidePanelHost stack OR a popped FloatingPanelWindow)
//   floating: g_floatingPanel.isVisible
// Used to detect host-initiated hides (e.g. user clicks the PanelFrame X,
// which gives the plugin no callback) so the menu toggle self-corrects.
static BOOL markdownPanelIsShown() {
    if (g_panelHandle > 0) {
        return sContentView != nil &&
               sContentView.window != nil &&
               sContentView.superview != nil;
    }
    if (g_floatingPanel) return g_floatingPanel.isVisible;
    return NO;
}

static void loadTemplateIntoWebView() {
    if (!sWebView || sFullTemplate.empty()) return;

    @autoreleasepool {
        // Write the HTML into the SAME directory as the markdown file so that
        // relative image paths (e.g., "subdir/image.png") resolve naturally.
        // WKWebView's <base> tag does NOT work for file:// image resolution,
        // so the HTML file must physically be in the right directory.
        std::string fp = getCurrentFilePath();
        NSString *markdownDir = nil;
        if (!fp.empty()) {
            markdownDir = [[NSString stringWithUTF8String:fp.c_str()] stringByDeletingLastPathComponent];
        }

        NSString *tmpPath;
        NSURL *accessURL;
        if (markdownDir && markdownDir.length > 0) {
            // Hidden temp file alongside the markdown file
            tmpPath = [markdownDir stringByAppendingPathComponent:@".npp-md-preview.html"];
            accessURL = [NSURL fileURLWithPath:markdownDir];
        } else {
            // Fallback for unsaved files — use temp directory
            tmpPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"npp-md-preview.html"];
            accessURL = [NSURL fileURLWithPath:NSTemporaryDirectory()];
        }

        // When squared is enabled, the preview imports the engine from the plugin
        // resources dir (a different tree). Widen the read-access scope to the common
        // ancestor of the preview file and the resources dir so the file:// import +
        // worker resolve. (Only when the feature is on.)
        if (sSettings.enableSquared) {
            NSString *htmlDir = [tmpPath stringByDeletingLastPathComponent];
            NSString *resDir  = [NSString stringWithUTF8String:sResourcesDir.c_str()];
            accessURL = [NSURL fileURLWithPath:commonAncestorDir(htmlDir, resDir)];
        }

        // Clean up previous temp file if it was in a different directory
        if (!sCurrentTempHtmlPath.empty()) {
            NSString *oldPath = [NSString stringWithUTF8String:sCurrentTempHtmlPath.c_str()];
            [[NSFileManager defaultManager] removeItemAtPath:oldPath error:nil];
        }
        sCurrentTempHtmlPath = std::string([tmpPath UTF8String]);

        NSString *htmlStr = [NSString stringWithUTF8String:sFullTemplate.c_str()];
        [htmlStr writeToFile:tmpPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSURL *fileURL = [NSURL fileURLWithPath:tmpPath];
        sWebViewReady = false;   // navigation starts now; -didFinishNavigation: flips it true
        [sWebView loadFileURL:fileURL allowingReadAccessToURL:accessURL];

        sTemplateLoaded = true;
        sLastRenderedText.clear();
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Markdown rendering
// ═══════════════════════════════════════════════════════════════════════════

static std::string getEditorText() {
    NppHandle h = getCurScintilla();
    if (!h) return "";
    intptr_t len = sci(h, SCI_GETLENGTH);
    if (len <= 0) return "";
    if (len > 5 * 1024 * 1024) return ""; // Skip files > 5MB

    std::string buf(len + 1, '\0');
    sci(h, SCI_GETTEXT, (uintptr_t)(len + 1), (intptr_t)buf.data());
    buf.resize(len);
    return buf;
}

static void renderMarkdownDirect() {
    if (!sPanelVisible || !sWebView) return;
    // Page not finished loading yet — injecting now would be lost (the
    // renderMarkdown() JS doesn't exist). -didFinishNavigation: will call us
    // again once the template is ready.
    if (!sWebViewReady) return;
    if (!isSupportedExtension()) {
        // Show "not a markdown file" message
        [sWebView evaluateJavaScript:
            @"document.getElementById('content').innerHTML = "
            "'<p style=\"color:#888;font-style:italic;\">Current file is not a Markdown file.</p>';"
            completionHandler:nil];
        return;
    }

    std::string text = getEditorText();
    if (text == sLastRenderedText) return; // No change
    sLastRenderedText = text;

    // Standalone .mmd files: wrap the entire content in a ```mermaid fence
    // so marked.js passes it to the Mermaid renderer
    std::string ext = getCurrentExtension();
    if (!ext.empty() && ext[0] == '.') ext = ext.substr(1);
    for (auto &c : ext) c = tolower(c);
    if (ext == "mmd") {
        text = "```mermaid\n" + text + "\n```\n";
    }

    // Check if baseURL needs updating (file path changed)
    std::string newPath = getCurrentFilePath();
    if (newPath != sCurrentFilePath) {
        sCurrentFilePath = newPath;
        // Full reload with new baseURL
        loadTemplateIntoWebView();
        // Schedule the render after page loads
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            renderMarkdownDirect();
        });
        return;
    }

    @autoreleasepool {
        // Escape the markdown text for JavaScript string injection
        NSString *nsText = [NSString stringWithUTF8String:text.c_str()];
        if (!nsText) nsText = @"";

        // Use JSON encoding to safely escape the string
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@[nsText] options:0 error:nil];
        if (!jsonData) return;
        NSString *jsonArray = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        // Extract the string from the JSON array: ["text"] → text
        // Remove leading [ and trailing ]
        NSString *jsonEscaped = [jsonArray substringWithRange:NSMakeRange(1, jsonArray.length - 2)];

        NSString *js = [NSString stringWithFormat:@"renderMarkdown(%@);", jsonEscaped];
        [sWebView evaluateJavaScript:js completionHandler:nil];
    }
}

static void renderMarkdownDeferred() {
    if (!sPanelVisible) return;
    if (sPendingRender) {
        dispatch_block_cancel(sPendingRender);
        sPendingRender = nil;
    }
    sPendingRender = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{
        renderMarkdownDirect();
        sPendingRender = nil;
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, RENDER_DEBOUNCE_MS * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), sPendingRender);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Scroll synchronization
// ═══════════════════════════════════════════════════════════════════════════

// Track BOTH the last caret line and the last first-visible line so a
// click that moves the caret without scrolling, and a wheel-scroll
// that moves the viewport without moving the caret, both trigger a
// preview sync. Earlier versions tracked only one of the two and
// chose based on a mutually-exclusive setting — that meant a user in
// "first-visible" mode got no preview update on click, and a user in
// "caret" mode got no preview update on wheel-scroll. With both
// modes independent, either trigger fires the sync as long as that
// mode is enabled.
static intptr_t sLastCaretLine        = -1;
static intptr_t sLastFirstVisibleLine = -1;
static dispatch_block_t sPendingScroll = nil;

static void syncScroll() {
    if (!sPanelVisible || !sWebView) return;

    NppHandle h = getCurScintilla();
    if (!h) return;

    intptr_t pos = sci(h, SCI_GETCURRENTPOS);
    intptr_t caretLine = sci(h, SCI_LINEFROMPOSITION, (uintptr_t)pos);
    intptr_t firstVisibleVis = sci(h, SCI_GETFIRSTVISIBLELINE);
    intptr_t firstVisibleDoc = sci(h, SCI_DOCLINEFROMVISIBLE,
                                    (uintptr_t)firstVisibleVis);

    // Pick the change to react to. Caret takes priority when it has
    // moved — that's the most direct "I'm interested in this line"
    // signal (click, arrow keys, page-down). When the caret hasn't
    // moved but the viewport has (mouse wheel, scrollbar drag), use
    // first-visible. If neither moved, nothing to do.
    intptr_t targetLine = -1;
    BOOL caretMoved        = (sSettings.syncWithCaret           &&
                              caretLine        != sLastCaretLine);
    BOOL firstVisibleMoved = (sSettings.syncWithFirstVisibleLine &&
                              firstVisibleDoc  != sLastFirstVisibleLine);

    if (caretMoved) {
        targetLine = caretLine;
    } else if (firstVisibleMoved) {
        targetLine = firstVisibleDoc;
    } else {
        return;
    }

    // Refresh both trackers regardless of which one we picked, so a
    // subsequent SCN_UPDATEUI doesn't fire a redundant scroll for a
    // change that was already covered.
    sLastCaretLine        = caretLine;
    sLastFirstVisibleLine = firstVisibleDoc;

    // Debounce scroll commands — SCN_UPDATEUI fires very frequently
    // (every paint, every selection change, every scroll tick).
    if (sPendingScroll) {
        dispatch_block_cancel(sPendingScroll);
        sPendingScroll = nil;
    }
    intptr_t capturedLine = targetLine;
    sPendingScroll = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{
        @autoreleasepool {
            NSString *js = [NSString stringWithFormat:@"scrollToLine(%ld);",
                                                       (long)capturedLine];
            [sWebView evaluateJavaScript:js completionHandler:nil];
        }
        sPendingScroll = nil;
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), sPendingScroll);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Menu commands
// ═══════════════════════════════════════════════════════════════════════════

static void togglePanel() {
    ensureContentView();
    if (sFullTemplate.empty()) buildTemplate();

    // First toggle after launch: try NPPM_DMM_REGISTERPANEL. A nonzero
    // return = host supports docking (v1.0.2+); cache the handle and use
    // the docked path for the lifetime of this plugin. Zero = older host,
    // fall back to the floating NSPanel.
    if (g_panelHandle == 0 && g_floatingPanel == nil) {
        intptr_t h = nppData._sendMessage(nppData._nppHandle,
                                          NPPM_DMM_REGISTERPANEL,
                                          (uintptr_t)(__bridge void *)sContentView,
                                          (intptr_t)"Markdown Panel");
        if (h > 0) {
            g_panelHandle = (uint64_t)h;
        } else {
            ensureFloatingPanel();
        }
    }

    // Target the OPPOSITE of the actual current state — this self-corrects
    // when the user has closed the panel through the host's PanelFrame X
    // (docked) without the plugin being notified: our cached sPanelVisible
    // might say "shown", but markdownPanelIsShown reads the live hierarchy
    // and returns NO, so we'll show again on next toggle.
    BOOL currentlyShown = markdownPanelIsShown();
    BOOL targetShown    = !currentlyShown;

    sPanelVisible = targetShown;
    npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[0]._cmdID, targetShown ? 1 : 0);

    if (targetShown) {
        if (g_panelHandle > 0) {
            nppData._sendMessage(nppData._nppHandle,
                                 NPPM_DMM_SHOWPANEL,
                                 (uintptr_t)g_panelHandle, 0);
        } else if (g_floatingPanel) {
            [g_floatingPanel orderFront:nil];
        }
        sCurrentFilePath.clear(); // Force baseURL update
        sLastRenderedText.clear();
        loadTemplateIntoWebView();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            renderMarkdownDirect();
        });
    } else {
        if (g_panelHandle > 0) {
            nppData._sendMessage(nppData._nppHandle,
                                 NPPM_DMM_HIDEPANEL,
                                 (uintptr_t)g_panelHandle, 0);
        } else if (g_floatingPanel) {
            [g_floatingPanel orderOut:nil];
        }
    }
}

// The two sync modes are independent — click-to-caret AND wheel-to-
// viewport can both be on simultaneously. Earlier versions made
// them mutually exclusive, which left users in one of two broken
// states (caret-only meant wheel scrolling didn't update the
// preview; first-visible-only meant clicking to a new line didn't
// update the preview). Each toggle now flips its own setting and
// leaves the other alone.
static void syncWithCaretCmd() {
    sSettings.syncWithCaret = !sSettings.syncWithCaret;
    npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[2]._cmdID, sSettings.syncWithCaret ? 1 : 0);
    saveSettings();
    sLastCaretLine        = -1;
    sLastFirstVisibleLine = -1;
    if (sSettings.syncWithCaret || sSettings.syncWithFirstVisibleLine) syncScroll();
}

static void syncWithFirstVisibleLineCmd() {
    sSettings.syncWithFirstVisibleLine = !sSettings.syncWithFirstVisibleLine;
    npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[3]._cmdID, sSettings.syncWithFirstVisibleLine ? 1 : 0);
    saveSettings();
    sLastCaretLine        = -1;
    sLastFirstVisibleLine = -1;
    if (sSettings.syncWithCaret || sSettings.syncWithFirstVisibleLine) syncScroll();
}

// Toolbar "refresh": force a full re-render — rebuild the HTML template and
// reload the WebView from scratch (clears the render/baseURL caches first).
static void refreshMarkdownPreview() {
    if (!sPanelVisible) return;
    sLastRenderedText.clear();
    sCurrentFilePath.clear();          // forces loadTemplateIntoWebView to rebuild
    buildTemplate();
    loadTemplateIntoWebView();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ renderMarkdownDirect(); });
}

// Toolbar "save as PDF": render the current preview to a PDF file via WKWebView.
static void saveMarkdownAsPDF() {
    if (!sPanelVisible || !sWebView) return;
    @autoreleasepool {
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"pdf"]];
        NSString *base = @"preview";
        std::string fp = getCurrentFilePath();
        if (!fp.empty()) {
            NSString *p = [[NSString stringWithUTF8String:fp.c_str()] lastPathComponent];
            NSString *stem = [p stringByDeletingPathExtension];
            if (stem.length) base = stem;
        }
        panel.nameFieldStringValue = [base stringByAppendingPathExtension:@"pdf"];
        if ([panel runModal] == NSModalResponseOK && panel.URL) {
            NSURL *dest = panel.URL;
            if (@available(macOS 11.0, *)) {
                WKPDFConfiguration *cfg = [[WKPDFConfiguration alloc] init];
                [sWebView createPDFWithConfiguration:cfg completionHandler:^(NSData *data, NSError *error) {
                    if (data) [data writeToURL:dest atomically:YES];
                    else NSLog(@"[MarkdownPanel] PDF export failed: %@", error);
                }];
            }
        }
    }
}

// Cmd +/- (and Cmd 0): adjust the preview zoom live via JS (no re-render) and
// persist. Reset is expressed as delta = 100 - current.
static void adjustPreviewZoom(int delta) {
    int z = sSettings.zoomLevel + delta;
    if (z < 50)  z = 50;
    if (z > 300) z = 300;
    if (z == sSettings.zoomLevel) return;
    sSettings.zoomLevel = z;
    if (sWebView && sWebViewReady) {
        NSString *js = [NSString stringWithFormat:@"document.body.style.zoom='%d%%';", z];
        [sWebView evaluateJavaScript:js completionHandler:nil];
    }
    saveSettings();
}

static void exportToHtmlCmd() {
    if (!sPanelVisible || !sWebView) return;
    @autoreleasepool {
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"html"]];
        panel.nameFieldStringValue = @"preview.html";

        if ([panel runModal] == NSModalResponseOK && panel.URL) {
            [sWebView evaluateJavaScript:@"document.documentElement.outerHTML"
                       completionHandler:^(id result, NSError *error) {
                if ([result isKindOfClass:[NSString class]]) {
                    NSString *html = (NSString *)result;
                    [html writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
            }];
        }
    }
}

// Live controller for the Settings dialog: gates the theme radios on the
// "Enable Squared flow diagrams" checkbox. Radio-group exclusivity is handled
// by AppKit (buttons sharing an action selector + superview are mutually exclusive).
@interface _NMPSettingsCtl : NSObject
// MRC (no ARC): the controller lives only for the synchronous modal, and the
// buttons/array survive via the content view + the enclosing autorelease pool,
// so plain assign is safe here.
@property (nonatomic, assign) NSButton *squaredCheck;
@property (nonatomic, assign) NSArray<NSButton *> *themeRadios;
@end
@implementation _NMPSettingsCtl
- (void)squaredToggled:(id)sender {
    BOOL on = self.squaredCheck.state == NSControlStateValueOn;
    for (NSButton *r in self.themeRadios) r.enabled = on;
}
- (void)themePicked:(id)sender { /* AppKit enforces radio-group exclusivity */ }
@end

static void showSettingsCmd() {
    @autoreleasepool {
        NSPanel *dlg = [[NSPanel alloc] initWithContentRect:NSMakeRect(200, 200, 420, 430)
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                    backing:NSBackingStoreBuffered defer:NO];
        [dlg setTitle:@"Markdown Panel Settings"];
        NSView *cv = [dlg contentView];
        _NMPSettingsCtl *ctl = [[_NMPSettingsCtl alloc] init];
        CGFloat y = 390;

        // Zoom
        NSTextField *zoomLabel = [NSTextField labelWithString:@"Zoom Level:"];
        zoomLabel.frame = NSMakeRect(20, y, 100, 20);
        [cv addSubview:zoomLabel];
        NSTextField *zoomField = [[NSTextField alloc] initWithFrame:NSMakeRect(130, y, 60, 24)];
        zoomField.stringValue = [NSString stringWithFormat:@"%d", sSettings.zoomLevel];
        [cv addSubview:zoomField];
        NSTextField *zoomPct = [NSTextField labelWithString:@"%"];
        zoomPct.frame = NSMakeRect(195, y, 20, 20);
        [cv addSubview:zoomPct];
        y -= 35;

        // Extensions
        NSTextField *extLabel = [NSTextField labelWithString:@"Supported extensions:"];
        extLabel.frame = NSMakeRect(20, y, 140, 20);
        [cv addSubview:extLabel];
        NSTextField *extField = [[NSTextField alloc] initWithFrame:NSMakeRect(170, y, 220, 24)];
        extField.stringValue = @(sSettings.supportedExtensions.c_str());
        [cv addSubview:extField];
        y -= 35;

        // Checkboxes
        NSButton *allExtCheck = [NSButton checkboxWithTitle:@"Allow all file extensions" target:nil action:nil];
        allExtCheck.frame = NSMakeRect(20, y, 350, 20);
        allExtCheck.state = sSettings.allowAllExtensions ? NSControlStateValueOn : NSControlStateValueOff;
        [cv addSubview:allExtCheck];
        y -= 28;

        NSButton *autoShowCheck = [NSButton checkboxWithTitle:@"Automatically show panel for supported files" target:nil action:nil];
        autoShowCheck.frame = NSMakeRect(20, y, 350, 20);
        autoShowCheck.state = sSettings.autoShowPanel ? NSControlStateValueOn : NSControlStateValueOff;
        [cv addSubview:autoShowCheck];
        y -= 28;

        NSButton *caretCheck = [NSButton checkboxWithTitle:@"Synchronize with caret position" target:nil action:nil];
        caretCheck.frame = NSMakeRect(20, y, 350, 20);
        caretCheck.state = sSettings.syncWithCaret ? NSControlStateValueOn : NSControlStateValueOff;
        [cv addSubview:caretCheck];
        y -= 28;

        NSButton *firstLineCheck = [NSButton checkboxWithTitle:@"Synchronize with first visible line" target:nil action:nil];
        firstLineCheck.frame = NSMakeRect(20, y, 350, 20);
        firstLineCheck.state = sSettings.syncWithFirstVisibleLine ? NSControlStateValueOn : NSControlStateValueOff;
        [cv addSubview:firstLineCheck];
        y -= 28;

        NSButton *mermaidCheck = [NSButton checkboxWithTitle:@"Enable Mermaid diagram rendering" target:nil action:nil];
        mermaidCheck.frame = NSMakeRect(20, y, 350, 20);
        mermaidCheck.state = sSettings.enableMermaid ? NSControlStateValueOn : NSControlStateValueOff;
        [cv addSubview:mermaidCheck];
        y -= 28;

        // Squared flow diagrams + theme radios, gated on the checkbox
        NSButton *squaredCheck = [NSButton checkboxWithTitle:@"Enable Squared flow diagrams"
                                                      target:ctl action:@selector(squaredToggled:)];
        squaredCheck.frame = NSMakeRect(20, y, 350, 20);
        squaredCheck.state = sSettings.enableSquared ? NSControlStateValueOn : NSControlStateValueOff;
        [cv addSubview:squaredCheck];
        y -= 26;

        // Display labels are Plain/Pastel/Blue; the engine's theme ids stay
        // boardroom/linen/blueprint (see the read-back below).
        NSButton *themeBoardroom = [NSButton radioButtonWithTitle:@"Plain" target:ctl action:@selector(themePicked:)];
        themeBoardroom.frame = NSMakeRect(40, y, 72, 20);
        NSButton *themeLinen = [NSButton radioButtonWithTitle:@"Pastel" target:ctl action:@selector(themePicked:)];
        themeLinen.frame = NSMakeRect(118, y, 78, 20);
        NSButton *themeBlueprint = [NSButton radioButtonWithTitle:@"Blue" target:ctl action:@selector(themePicked:)];
        themeBlueprint.frame = NSMakeRect(202, y, 66, 20);
        NSString *curTheme = @(sSettings.squaredTheme.c_str());
        themeLinen.state     = [curTheme isEqualToString:@"linen"]     ? NSControlStateValueOn : NSControlStateValueOff;
        themeBlueprint.state = [curTheme isEqualToString:@"blueprint"] ? NSControlStateValueOn : NSControlStateValueOff;
        themeBoardroom.state = (themeLinen.state == NSControlStateValueOn ||
                                themeBlueprint.state == NSControlStateValueOn)
                                 ? NSControlStateValueOff : NSControlStateValueOn;
        {
            BOOL sq = sSettings.enableSquared;
            themeBoardroom.enabled = sq; themeLinen.enabled = sq; themeBlueprint.enabled = sq;
        }
        [cv addSubview:themeBoardroom];
        [cv addSubview:themeLinen];
        [cv addSubview:themeBlueprint];
        ctl.squaredCheck = squaredCheck;
        ctl.themeRadios  = @[themeBoardroom, themeLinen, themeBlueprint];
        y -= 40;

        // Save button
        NSButton *saveBtn = [NSButton buttonWithTitle:@"Save" target:NSApp action:@selector(stopModal)];
        saveBtn.frame = NSMakeRect(310, y, 80, 30);
        saveBtn.keyEquivalent = @"\r";
        [cv addSubview:saveBtn];

        // Close observer
        id observer = [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowWillCloseNotification object:dlg queue:nil
                   usingBlock:^(NSNotification *n) { [NSApp stopModal]; }];

        [NSApp runModalForWindow:dlg];
        [[NSNotificationCenter defaultCenter] removeObserver:observer];

        // Read values
        bool needsReload = false;
        int newZoom = [zoomField.stringValue intValue];
        if (newZoom < 50) newZoom = 50;
        if (newZoom > 300) newZoom = 300;
        if (newZoom != sSettings.zoomLevel) { sSettings.zoomLevel = newZoom; needsReload = true; }
        sSettings.supportedExtensions = [extField.stringValue UTF8String];
        sSettings.allowAllExtensions = allExtCheck.state == NSControlStateValueOn;
        sSettings.autoShowPanel = autoShowCheck.state == NSControlStateValueOn;
        sSettings.syncWithCaret = caretCheck.state == NSControlStateValueOn;
        sSettings.syncWithFirstVisibleLine = firstLineCheck.state == NSControlStateValueOn;
        bool newMermaid = mermaidCheck.state == NSControlStateValueOn;
        if (newMermaid != sSettings.enableMermaid) { sSettings.enableMermaid = newMermaid; needsReload = true; }
        bool newSquared = squaredCheck.state == NSControlStateValueOn;
        if (newSquared != sSettings.enableSquared) { sSettings.enableSquared = newSquared; needsReload = true; }
        std::string newTheme = themeLinen.state == NSControlStateValueOn ? "linen"
                             : themeBlueprint.state == NSControlStateValueOn ? "blueprint" : "boardroom";
        if (newTheme != sSettings.squaredTheme) { sSettings.squaredTheme = newTheme; needsReload = true; }

        // Update checkmarks
        npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[2]._cmdID, sSettings.syncWithCaret ? 1 : 0);
        npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[3]._cmdID, sSettings.syncWithFirstVisibleLine ? 1 : 0);

        saveSettings();
        [dlg close];

        if (needsReload && sPanelVisible) {
            buildTemplate();
            sCurrentFilePath.clear();
            sLastRenderedText.clear();
            loadTemplateIntoWebView();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{ renderMarkdownDirect(); });
        }
    }
}

static void showHelpCmd() {
    // Open the bundled help.md file in Notepad++ (and show the preview panel)
    static std::string sHelpPath;
    sHelpPath = sResourcesDir + "/help.md";
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:[NSString stringWithUTF8String:sHelpPath.c_str()]]) {
            nppData._sendMessage(nppData._nppHandle, NPPM_DOOPEN, 0, (intptr_t)sHelpPath.c_str());
            // Auto-show the panel so the user sees the rendered help
            if (!sPanelVisible) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{ togglePanel(); });
            }
        } else {
            [[NSWorkspace sharedWorkspace] openURL:
                [NSURL URLWithString:@"https://github.com/notepad-plus-plus-mac/NppMarkdownPanel"]];
        }
    }
}

static void showAboutCmd() {
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Markdown Panel";
        alert.informativeText =
            @"Markdown Panel for Notepad++ (macOS port)\n\n"
            "Real-time Markdown preview with GitHub-flavored rendering.\n\n"
            "Features:\n"
            "- Live preview as you type\n"
            "- Syntax highlighting for code blocks\n"
            "- Relative image support\n"
            "- Dark mode support\n"
            "- Scroll synchronization\n"
            "- Export to HTML\n"
            "- YAML frontmatter display\n"
            "- Mermaid diagram support (optional)\n\n"
            "Rendering: marked.js + highlight.js in WKWebView\n\n"
            "Original Windows plugin by Jens Wollgarten (GPLv2)\n"
            "macOS port using native WebKit rendering.";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Plugin exports
// ═══════════════════════════════════════════════════════════════════════════

extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;
    sResourcesDir = findResourcesDir();
    loadSettings();

    int idx = 0;
    auto addItem = [&](const char *name, PFUNCPLUGINCMD func) {
        strlcpy(funcItem[idx]._itemName, name, NPP_MENU_ITEM_SIZE);
        funcItem[idx]._pFunc = func;
        funcItem[idx]._init2Check = false;
        funcItem[idx]._pShKey = nullptr;
        idx++;
    };
    auto addSep = [&]() {
        funcItem[idx]._itemName[0] = '\0';
        funcItem[idx]._pFunc = nullptr;
        funcItem[idx]._init2Check = false;
        funcItem[idx]._pShKey = nullptr;
        idx++;
    };

    addItem("Toggle Markdown Panel",                togglePanel);        // 0
    addSep();                                                             // 1
    addItem("Synchronize with caret position",      syncWithCaretCmd);   // 2
    addItem("Synchronize with first visible line",  syncWithFirstVisibleLineCmd); // 3
    addSep();                                                             // 4
    addItem("Settings",                             showSettingsCmd);     // 5
    addItem("Help",                                 showHelpCmd);         // 6
    addItem("About",                                showAboutCmd);        // 7

    // Set initial checkmarks for sync modes
    funcItem[2]._init2Check = sSettings.syncWithCaret;
    funcItem[3]._init2Check = sSettings.syncWithFirstVisibleLine;
}

extern "C" NPP_EXPORT const char *getName() {
    return PLUGIN_NAME;
}

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) {
    *nbF = NB_FUNC;
    return funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    switch (n->nmhdr.code) {
        case NPPN_TBMODIFICATION:
            // Register toolbar icon — host looks for toolbar.png in the plugin's directory
            nppData._sendMessage(nppData._nppHandle, NPPM_ADDTOOLBARICON_FORDARKMODE,
                                 (uintptr_t)funcItem[0]._cmdID,
                                 (intptr_t)"toolbar.png");
            break;

        case NPPN_READY:
            // Auto-show if configured
            if (sSettings.autoShowPanel && isSupportedExtension()) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!sPanelVisible) togglePanel();
                });
            }
            break;

        case NPPN_BUFFERACTIVATED:
            if (sPanelVisible) {
                sLastRenderedText.clear();
                sCurrentFilePath.clear();
                sLastCaretLine        = -1;
                sLastFirstVisibleLine = -1;
                renderMarkdownDeferred();

                // Auto-show/hide based on extension
                if (sSettings.autoShowPanel) {
                    // Panel is visible — just re-render, the render function
                    // handles "not a markdown file" display
                }
            }
            break;

        case SCN_MODIFIED:
            if (sPanelVisible && (n->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT))) {
                renderMarkdownDeferred();
            }
            break;

        case SCN_UPDATEUI:
            if (sPanelVisible) {
                syncScroll();
            }
            break;

        case NPPN_SHUTDOWN:
            saveSettings();
            // Clean up temp preview file
            if (!sCurrentTempHtmlPath.empty()) {
                [[NSFileManager defaultManager]
                    removeItemAtPath:[NSString stringWithUTF8String:sCurrentTempHtmlPath.c_str()]
                               error:nil];
                sCurrentTempHtmlPath.clear();
            }
            // Release the host's retain on sContentView before the dylib
            // is unloaded — harmless if we never registered (older host,
            // floating path). Matches XmlNavigator's shutdown pattern.
            if (g_panelHandle > 0) {
                nppData._sendMessage(nppData._nppHandle,
                                     NPPM_DMM_UNREGISTERPANEL,
                                     (uintptr_t)g_panelHandle, 0);
                g_panelHandle = 0;
            }
            if (g_floatingPanel) {
                [g_floatingPanel close];
                g_floatingPanel = nil;
            }
            if (sPendingSearch) {
                dispatch_block_cancel(sPendingSearch);
                sPendingSearch = nil;
            }
            if (sZoomKeyMonitor) {
                [NSEvent removeMonitor:sZoomKeyMonitor];
                sZoomKeyMonitor = nil;
            }
            sSearchField    = nil;
            sPrintButton    = nil;
            sSettingsButton = nil;
            sRefreshButton  = nil;
            sPdfButton      = nil;
            sSearchDelegate = nil;
            sContentView    = nil;
            sWebView        = nil;
            sNavDelegate    = nil;
            break;

        default:
            break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) {
    return 1;
}
