package tests

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// Runbooks are read under pressure, at 03:00, by an operator who cannot debug
// them. Every `activity-log <verb>` they name must therefore exist. Four
// runbooks drifted onto commands that were never implemented (reindex, archive,
// ingest, ulids) and stayed that way because nothing checked.
var docCommandRe = regexp.MustCompile(`activity-log ([a-z][a-z-]*)`)

// Words that follow "activity-log" in prose without naming a subcommand.
var notACommand = map[string]bool{
	"binary": true, "emits": true, "is": true, "and": true, "to": true,
	"on": true, "in": true, "the": true, "with": true, "for": true,
	"or": true, "from": true, "at": true, "as": true, "not": true,
	"then": true, "must": true, "can": true, "will": true, "does": true,
}

func realCommands(t *testing.T) map[string]bool {
	t.Helper()
	bin := buildActivityLog(t)
	out, err := exec.Command(bin, "--help").CombinedOutput()
	if err != nil {
		t.Fatalf("activity-log --help: %v\n%s", err, out)
	}
	cmds := map[string]bool{"help": true, "completion": true}
	inList := false
	for _, line := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(line, "Available Commands:") {
			inList = true
			continue
		}
		if inList {
			if strings.TrimSpace(line) == "" {
				break
			}
			if f := strings.Fields(line); len(f) > 0 {
				cmds[f[0]] = true
			}
		}
	}
	if len(cmds) < 5 {
		t.Fatalf("could not parse the command list from --help:\n%s", out)
	}
	return cmds
}

func docFiles(t *testing.T) []string {
	t.Helper()
	var files []string
	for _, pattern := range []string{
		filepath.Join("..", "health", "runbook", "*.md"),
		filepath.Join("..", "ARCHITECTURE.md"),
		filepath.Join("..", "README.md"),
	} {
		matches, err := filepath.Glob(pattern)
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, matches...)
	}
	if len(files) == 0 {
		t.Fatal("no doc files found — glob is wrong")
	}
	return files
}

func TestDocsOnlyReferenceRealCommands(t *testing.T) {
	cmds := realCommands(t)
	bin := buildActivityLog(t)
	// `--help` lists primary names only, so resolve anything else through the
	// binary itself — that also accepts registered aliases.
	resolvable := func(verb string) bool {
		return exec.Command(bin, verb, "--help").Run() == nil
	}
	bad := map[string][]string{}
	for _, path := range docFiles(t) {
		buf, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range docCommandRe.FindAllStringSubmatch(string(buf), -1) {
			verb := m[1]
			if notACommand[verb] || cmds[verb] || resolvable(verb) {
				continue
			}
			bad[filepath.Base(path)] = append(bad[filepath.Base(path)], verb)
		}
	}
	if len(bad) == 0 {
		return
	}
	names := make([]string, 0, len(bad))
	for k := range bad {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, n := range names {
		t.Errorf("%s references non-existent subcommand(s): %v", n, bad[n])
	}
	have := make([]string, 0, len(cmds))
	for c := range cmds {
		have = append(have, c)
	}
	sort.Strings(have)
	t.Logf("real subcommands: %v", have)
}

// Runbooks also point at repo files. A path that moved (installers/macos/,
// deleted Windows templates) sends the operator down a dead end.
func TestRunbooksReferenceExistingRepoPaths(t *testing.T) {
	pathRe := regexp.MustCompile(`\b(installers|health|hooks|configs|registries|integration|mcp|docs)/[A-Za-z0-9._/-]+`)
	matches, err := filepath.Glob(filepath.Join("..", "health", "runbook", "*.md"))
	if err != nil {
		t.Fatal(err)
	}
	for _, doc := range matches {
		buf, err := os.ReadFile(doc)
		if err != nil {
			t.Fatal(err)
		}
		for _, ref := range pathRe.FindAllString(string(buf), -1) {
			ref = strings.TrimRight(ref, ".,;:)`")
			if strings.Contains(ref, "*") {
				continue
			}
			if _, err := os.Stat(filepath.Join("..", ref)); err != nil {
				t.Errorf("%s references missing path %q", filepath.Base(doc), ref)
			}
		}
	}
}
