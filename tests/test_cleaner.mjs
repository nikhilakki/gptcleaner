#!/usr/bin/env node
// Tests for the JavaScript engine (web/cleaner.js).
//
//     node tests/test_cleaner.mjs
//
// Reads the same tests/cases.json as the Python suite - that shared fixture is
// what stops the two engines from drifting apart.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createRequire } from "node:module";

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const GPTCleaner = require(join(here, "..", "skills", "gptcleaner", "web", "cleaner.js"));
const CASES = JSON.parse(readFileSync(join(here, "cases.json"), "utf8"));

let passed = 0;
const failures = [];

function check(name, got, want) {
  if (got === want || (typeof got === "object" && JSON.stringify(got) === JSON.stringify(want))) {
    passed++;
  } else {
    failures.push({ name, got, want });
  }
}

// ---- shared clean cases ----
for (const c of CASES.cases) {
  check("clean: " + c.name, GPTCleaner.clean(c.in, c.options || {}).text, c.out);
}

// ---- shared scan cases ----
for (const c of CASES.scans) {
  const got = GPTCleaner.scan(c.in).map((h) => ({ code: h.code, name: h.name, count: h.count }));
  check("scan: " + c.name, got, c.expect);
}

// ---- report accounting ----
{
  const r = GPTCleaner.clean("a​b “q” — c d").report;
  check("report: hidden count", r.hiddenTotal, 2);
  check("report: punctuation count", r.punctuationTotal, 3);
}

// ---- idempotence: cleaning twice equals cleaning once ----
for (const markdown of [false, true]) {
  for (const s of ["﻿# T​itle\r\n\r\n\r\nIt’s “fine” — **bold**  text…",
                   "- one\n\n\n* two\n\n\n\n three   ", "plain"]) {
    const once = GPTCleaner.clean(s, { markdown }).text;
    const twice = GPTCleaner.clean(once, { markdown }).text;
    check(`idempotent (markdown=${markdown}): ${JSON.stringify(s.slice(0, 20))}`, twice, once);
  }
}

// ---- cleaned output has no residue ----
for (const s of ["﻿a​b c", "x⁠y"]) {
  check("no residue: " + JSON.stringify(s), GPTCleaner.scan(GPTCleaner.clean(s).text).length, 0);
}

// ---- options default to the full preset, like the Python clean() ----
check("clean() with no options", GPTCleaner.clean("a​b — c").text, "ab - c");

// ---- report ----
const total = passed + failures.length;
if (failures.length) {
  console.error(`\n${failures.length} of ${total} JS checks FAILED:\n`);
  for (const f of failures) {
    console.error(`  ${f.name}\n    got:  ${JSON.stringify(f.got)}\n    want: ${JSON.stringify(f.want)}`);
  }
  process.exit(1);
}
console.log(`ok - ${passed} JavaScript checks passed`);
