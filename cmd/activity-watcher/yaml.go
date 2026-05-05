// Tiny YAML subset parser tailored to watcher.yaml.
//
// Supports the schema we actually use:
//
//	activity_log_bin: /path/to/bin
//	debounce_ms: 5000
//	sources:
//	  - name: foo
//	    path: ~/something
//	    pattern: "*.md"
//	    op: create
//	    recursive: true
//	    diff_field: enabledPlugins
//	    summary_template: "..."        # alias for emit.summary_template
//	    emit:
//	      kind: install
//	      kind_template: "..."
//	      scope: claude-mac
//	      scope_template: "..."
//	      agent: claude-mac
//	      priority: P2
//	      tags: [a, b]
//	      summary_template: "..."
//
// We do NOT pull in gopkg.in/yaml.v3 — the dep budget is fsnotify only.
// This parser is line-oriented, indentation-driven, and intentionally
// strict: anything outside the schema above will return an error.
package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// loadConfig reads + parses watcher.yaml.
func loadConfig(path string) (*Config, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var lines []rawLine
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 8<<20)
	for lineNo := 1; sc.Scan(); lineNo++ {
		raw := sc.Text()
		// strip trailing comments unless inside a quoted string.
		if idx := stripComment(raw); idx >= 0 {
			raw = raw[:idx]
		}
		raw = strings.TrimRight(raw, " \t\r")
		if strings.TrimSpace(raw) == "" {
			continue
		}
		indent := countIndent(raw)
		lines = append(lines, rawLine{n: lineNo, indent: indent, text: raw[indent:]})
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}

	cfg := &Config{}
	if err := parseTop(lines, cfg); err != nil {
		return nil, err
	}
	return cfg, nil
}

type rawLine struct {
	n      int
	indent int
	text   string
}

func countIndent(s string) int {
	n := 0
	for _, c := range s {
		if c == ' ' {
			n++
			continue
		}
		if c == '\t' {
			n += 2
			continue
		}
		break
	}
	return n
}

// stripComment returns the index of an unquoted '#' or -1 if none.
func stripComment(s string) int {
	inQuote := byte(0)
	for i := 0; i < len(s); i++ {
		c := s[i]
		if inQuote != 0 {
			if c == inQuote && (i == 0 || s[i-1] != '\\') {
				inQuote = 0
			}
			continue
		}
		if c == '"' || c == '\'' {
			inQuote = c
			continue
		}
		if c == '#' {
			return i
		}
	}
	return -1
}

// splitKV splits "key: value" honouring quotes. Empty value → ("", "", true).
func splitKV(s string) (string, string, bool) {
	idx := strings.Index(s, ":")
	if idx < 0 {
		return "", "", false
	}
	k := strings.TrimSpace(s[:idx])
	v := strings.TrimSpace(s[idx+1:])
	return k, v, true
}

// unquote strips surrounding "..." or '...' if present.
func unquote(s string) string {
	if len(s) >= 2 && (s[0] == '"' || s[0] == '\'') && s[0] == s[len(s)-1] {
		return s[1 : len(s)-1]
	}
	return s
}

// parseList parses inline list  "[a, b, c]"  or returns nil if not bracketed.
func parseInlineList(s string) ([]string, bool) {
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(s, "[") || !strings.HasSuffix(s, "]") {
		return nil, false
	}
	inner := strings.TrimSpace(s[1 : len(s)-1])
	if inner == "" {
		return nil, true
	}
	parts := strings.Split(inner, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		out = append(out, unquote(strings.TrimSpace(p)))
	}
	return out, true
}

// parseTop walks top-level scalar keys + the list-of-maps "sources".
func parseTop(lines []rawLine, cfg *Config) error {
	i := 0
	for i < len(lines) {
		ln := lines[i]
		if ln.indent != 0 {
			return fmt.Errorf("line %d: unexpected indent at top level", ln.n)
		}
		k, v, ok := splitKV(ln.text)
		if !ok {
			return fmt.Errorf("line %d: expected key: value (got %q)", ln.n, ln.text)
		}
		switch k {
		case "activity_log_bin":
			cfg.ActivityLogBin = unquote(v)
			i++
		case "debounce_ms":
			n, err := strconv.Atoi(unquote(v))
			if err != nil {
				return fmt.Errorf("line %d: debounce_ms: %v", ln.n, err)
			}
			cfg.DebounceMs = n
			i++
		case "sources":
			if v != "" {
				return fmt.Errorf("line %d: sources must be a block list (no inline value)", ln.n)
			}
			i++
			j, err := parseSources(lines, i, cfg)
			if err != nil {
				return err
			}
			i = j
		default:
			return fmt.Errorf("line %d: unknown top-level key %q", ln.n, k)
		}
	}
	return nil
}

// parseSources reads a block list "  - name: ...\n    path: ...\n  - name: ...".
// Returns the index of the next line beyond the block.
func parseSources(lines []rawLine, start int, cfg *Config) (int, error) {
	if start >= len(lines) {
		return start, nil
	}
	listIndent := lines[start].indent
	if listIndent < 2 {
		return start, fmt.Errorf("line %d: sources list must be indented (≥2 spaces)", lines[start].n)
	}
	i := start
	for i < len(lines) && lines[i].indent >= listIndent {
		ln := lines[i]
		if ln.indent != listIndent || !strings.HasPrefix(ln.text, "- ") {
			// end of the sources block — let parseTop loop pick up next key.
			break
		}
		// First line of a list item: "- key: value" → already a kv inside the
		// item's map. Drop the leading "- " and use that line as part of the
		// item map.
		first := strings.TrimSpace(strings.TrimPrefix(ln.text, "- "))
		itemLines := []rawLine{{n: ln.n, indent: 0, text: first}}
		// gather subsequent indented lines as part of the item.
		j := i + 1
		for j < len(lines) && lines[j].indent > listIndent {
			itemLines = append(itemLines, rawLine{n: lines[j].n, indent: lines[j].indent - listIndent - 2, text: lines[j].text})
			j++
		}
		src, err := parseSourceBlock(itemLines)
		if err != nil {
			return 0, err
		}
		cfg.Sources = append(cfg.Sources, src)
		i = j
	}
	return i, nil
}

func parseSourceBlock(lines []rawLine) (Source, error) {
	src := Source{}
	i := 0
	for i < len(lines) {
		ln := lines[i]
		if ln.indent != 0 {
			return src, fmt.Errorf("line %d: unexpected indent inside source", ln.n)
		}
		k, v, ok := splitKV(ln.text)
		if !ok {
			return src, fmt.Errorf("line %d: bad k:v inside source: %q", ln.n, ln.text)
		}
		switch k {
		case "name":
			src.Name = unquote(v)
		case "path":
			src.Path = unquote(v)
		case "pattern":
			src.Pattern = unquote(v)
		case "op":
			src.Op = unquote(v)
		case "recursive":
			src.Recursive = unquote(v) == "true"
		case "diff_field":
			src.DiffField = unquote(v)
		case "summary_template":
			src.SummaryTemplate = unquote(v)
		case "emit":
			if v != "" {
				return src, fmt.Errorf("line %d: emit must be a block (no inline value)", ln.n)
			}
			// gather indented sub-lines
			j := i + 1
			var sub []rawLine
			for j < len(lines) && lines[j].indent > 0 {
				sub = append(sub, rawLine{n: lines[j].n, indent: lines[j].indent - 2, text: lines[j].text})
				j++
			}
			emit, err := parseEmitBlock(sub)
			if err != nil {
				return src, err
			}
			src.Emit = emit
			i = j
			continue
		default:
			return src, fmt.Errorf("line %d: unknown source key %q", ln.n, k)
		}
		i++
	}
	if src.Name == "" || src.Path == "" {
		return src, fmt.Errorf("source missing name or path: %+v", src)
	}
	return src, nil
}

func parseEmitBlock(lines []rawLine) (Emit, error) {
	e := Emit{}
	for _, ln := range lines {
		if ln.indent != 0 {
			return e, fmt.Errorf("line %d: unexpected indent in emit", ln.n)
		}
		k, v, ok := splitKV(ln.text)
		if !ok {
			return e, fmt.Errorf("line %d: bad k:v in emit: %q", ln.n, ln.text)
		}
		switch k {
		case "kind":
			e.Kind = unquote(v)
		case "kind_template":
			e.KindTemplate = unquote(v)
		case "scope":
			e.Scope = unquote(v)
		case "scope_template":
			e.ScopeTemplate = unquote(v)
		case "agent":
			e.Agent = unquote(v)
		case "priority":
			e.Priority = unquote(v)
		case "summary_template":
			e.SummaryTemplate = unquote(v)
		case "tags":
			if list, ok := parseInlineList(v); ok {
				e.Tags = list
			} else {
				return e, fmt.Errorf("line %d: tags must be inline list [a,b,c]", ln.n)
			}
		default:
			return e, fmt.Errorf("line %d: unknown emit key %q", ln.n, k)
		}
	}
	return e, nil
}
