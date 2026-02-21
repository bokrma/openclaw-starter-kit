#!/usr/bin/env node

import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const SECTION_ORDER = [
  "AGENT.md",
  "SOUL.md",
  "TOOLS.md",
  "IDENTITY.md",
  "USER.md",
  "HEARTBEAT.md",
  "BOOTSTRAP.md",
  "MEMORY.md",
];

const SECTION_ALIASES = new Map([
  ["IDENITY.md", "IDENTITY.md"],
]);

const OUTPUT_FILE_MAP = {
  "AGENT.md": "AGENTS.md",
  "SOUL.md": "SOUL.md",
  "TOOLS.md": "TOOLS.md",
  "IDENTITY.md": "IDENTITY.md",
  "USER.md": "USER.md",
  "HEARTBEAT.md": "HEARTBEAT.md",
  "BOOTSTRAP.md": "BOOTSTRAP.md",
  "MEMORY.md": "MEMORY.md",
};

const SKIP_FILENAMES = new Set(["00_MASTER_INDEX.md"]);
const TRAILING_ID_TOKENS = new Set(["agent", "engineer", "expert"]);
const ACRONYMS = new Set(["PM", "QA", "UI", "UX", "AI", "ML"]);
const DEFAULT_AGENT_NAMES = new Map([
  ["main", "Jarvis"],
  ["backend", "Backend Engineer"],
  ["creative", "Creative Agent"],
  ["database", "Database Engineer"],
  ["designer", "Designer"],
  ["devops", "DevOps Agent"],
  ["financial", "Financial Expert"],
  ["frontend", "Frontend Engineer"],
  ["growth", "Growth Agent"],
  ["motivation", "Motivation Agent"],
  ["pm", "PM Agent"],
  ["qa", "QA Engineer"],
  ["research", "Research Engineer"],
  ["uiux", "UI/UX Expert"],
]);

function parseArgs(argv) {
  const args = {
    sourceDir: "openclaw-agents",
    outputDir: "openclaw-agents/agents",
    manifest: "",
    quiet: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--source-dir") {
      i += 1;
      args.sourceDir = argv[i] ?? args.sourceDir;
      continue;
    }
    if (arg === "--output-dir") {
      i += 1;
      args.outputDir = argv[i] ?? args.outputDir;
      continue;
    }
    if (arg === "--manifest") {
      i += 1;
      args.manifest = argv[i] ?? args.manifest;
      continue;
    }
    if (arg === "--quiet") {
      args.quiet = true;
      continue;
    }
    if (arg === "-h" || arg === "--help") {
      printHelp();
      process.exit(0);
    }
  }

  return args;
}

function printHelp() {
  process.stdout.write(
    [
      "Usage: node scripts/split_openclaw_agents.mjs [options]",
      "",
      "Options:",
      "  --source-dir <dir>   Source merged agent markdown directory (default: openclaw-agents)",
      "  --output-dir <dir>   Split output directory (default: openclaw-agents/agents)",
      "  --manifest <file>    Manifest output path (default: <output-dir>/manifest.json)",
      "  --quiet              Suppress progress output",
      "  -h, --help           Show help",
      "",
    ].join("\n"),
  );
}

function normalizeWord(word) {
  const token = word.trim();
  if (!token) {
    return token;
  }
  const upper = token.toUpperCase();
  if (ACRONYMS.has(upper)) {
    return upper;
  }
  if (upper === "DEVOPS") {
    return "DevOps";
  }
  if (upper === "UI/UX") {
    return "UI/UX";
  }
  if (token === token.toUpperCase()) {
    return token.charAt(0) + token.slice(1).toLowerCase();
  }
  return token;
}

function normalizeDisplayName(raw) {
  return raw
    .split(/\s+/)
    .filter(Boolean)
    .map((item) => {
      if (!item.includes("/")) {
        return normalizeWord(item);
      }
      return item
        .split("/")
        .map((part) => normalizeWord(part))
        .join("/");
    })
    .join(" ")
    .trim();
}

function deriveName(text, stem) {
  const headerMatch = text.match(/^#\s+(.+?)\s*$/m);
  if (headerMatch) {
    const titleRaw = headerMatch[1]?.trim() ?? "";
    const title = titleRaw.split(/\s+[-\u2013\u2014]\s+/u)[0]?.trim() ?? "";
    if (title) {
      return normalizeDisplayName(title);
    }
  }
  const fallback = stem
    .split(/[_\W]+/u)
    .filter(Boolean)
    .join(" ");
  return normalizeDisplayName(fallback);
}

function deriveAgentId(stem) {
  if (stem.toUpperCase() === "JARVIS") {
    return { id: "main", isDefault: true };
  }
  const tokens = stem
    .split(/[_\W]+/u)
    .filter(Boolean)
    .map((item) => item.toLowerCase());
  while (tokens.length > 1 && TRAILING_ID_TOKENS.has(tokens[tokens.length - 1])) {
    tokens.pop();
  }
  let id = tokens.join("-");
  if (!id) {
    id = "agent";
  }
  id = id.replace(/[^a-z0-9_-]+/gu, "-").replace(/^-+|-+$/gu, "");
  if (!id) {
    id = "agent";
  }
  return { id: id.slice(0, 64), isDefault: false };
}

function humanizeAgentId(id) {
  if (DEFAULT_AGENT_NAMES.has(id)) {
    return DEFAULT_AGENT_NAMES.get(id);
  }
  const rawTokens = id.split(/[-_]+/u).filter(Boolean);
  if (rawTokens.length === 0) {
    return "Agent";
  }
  return rawTokens
    .map((token) => {
      if (token === "uiux") {
        return "UI/UX";
      }
      return normalizeWord(token);
    })
    .join(" ");
}

function hasSpecificName(name, id) {
  const value = String(name ?? "").trim();
  if (!value) {
    return false;
  }
  return value.toLowerCase() !== id.toLowerCase();
}

function deriveNameFromRole(agentSpec) {
  const roleMatch = agentSpec.match(/^ROLE:\s*(.+?)\s*$/im);
  if (!roleMatch) {
    return "";
  }
  const role = roleMatch[1].trim();
  if (!role) {
    return "";
  }
  const concise = role.split(/[&,]/u)[0]?.trim() ?? role;
  return normalizeDisplayName(concise);
}

function extractSections(text, sourceName) {
  const lines = text.split(/\r?\n/u);
  const sections = new Map();

  for (let idx = 0; idx < lines.length; idx += 1) {
    const line = lines[idx].trim();
    if (!line.startsWith("## ")) {
      continue;
    }
    const rawHeading = line.slice(3).trim();
    const heading = SECTION_ALIASES.get(rawHeading) ?? rawHeading;
    if (!SECTION_ORDER.includes(heading)) {
      continue;
    }

    idx += 1;
    while (idx < lines.length && lines[idx].trim() === "") {
      idx += 1;
    }

    if (idx >= lines.length || !lines[idx].trim().startsWith("```")) {
      throw new Error(`${sourceName}: expected fenced code block after section '${heading}'`);
    }

    idx += 1;
    const body = [];
    while (idx < lines.length && !lines[idx].trim().startsWith("```")) {
      body.push(lines[idx]);
      idx += 1;
    }
    if (idx >= lines.length) {
      throw new Error(`${sourceName}: unterminated fenced block for section '${heading}'`);
    }

    const content = body.join("\n").replace(/^\n+|\n+$/gu, "");
    sections.set(heading, `${content}\n`);
  }

  const missing = SECTION_ORDER.filter((name) => !sections.has(name));
  if (missing.length > 0) {
    throw new Error(`${sourceName}: missing required sections: ${missing.join(", ")}`);
  }

  return sections;
}

function sortManifestAgents(agents) {
  agents.sort((left, right) => {
    const leftRank = left.default ? 0 : 1;
    const rightRank = right.default ? 0 : 1;
    if (leftRank !== rightRank) {
      return leftRank - rightRank;
    }
    return left.id.localeCompare(right.id);
  });
}

async function loadExistingManifestAgents(manifestPath) {
  try {
    const raw = await fs.readFile(manifestPath, "utf8");
    const parsed = JSON.parse(raw);
    const result = new Map();
    const agents = Array.isArray(parsed?.agents) ? parsed.agents : [];
    for (const item of agents) {
      const id = String(item?.id ?? "").trim();
      if (!id) {
        continue;
      }
      result.set(id, {
        name: String(item?.name ?? "").trim(),
        default: item?.default === true,
        sourceFile: typeof item?.sourceFile === "string" ? item.sourceFile.trim() : null,
      });
    }
    return result;
  } catch {
    return new Map();
  }
}

async function buildManifestFromSplitDirectory(outputDir, existingManifestAgents) {
  let entries = [];
  try {
    entries = await fs.readdir(outputDir, { withFileTypes: true });
  } catch {
    return [];
  }

  const directories = entries
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort((left, right) => left.localeCompare(right));

  const agents = [];
  for (const id of directories) {
    const agentDir = path.join(outputDir, id);
    const missing = [];
    for (const sectionName of SECTION_ORDER) {
      const outputName = OUTPUT_FILE_MAP[sectionName];
      const fullPath = path.join(agentDir, outputName);
      try {
        await fs.access(fullPath);
      } catch {
        missing.push(outputName);
      }
    }
    if (missing.length > 0) {
      throw new Error(
        `Split directory '${agentDir}' is missing required files: ${missing.join(", ")}`,
      );
    }

    const agentSpec = await fs.readFile(path.join(agentDir, "AGENTS.md"), "utf8");
    const existing = existingManifestAgents.get(id);

    let displayName = "";
    if (hasSpecificName(existing?.name, id)) {
      displayName = existing.name;
    } else if (DEFAULT_AGENT_NAMES.has(id)) {
      displayName = DEFAULT_AGENT_NAMES.get(id);
    } else {
      const fromRole = deriveNameFromRole(agentSpec);
      if (hasSpecificName(fromRole, id)) {
        displayName = fromRole;
      } else {
        displayName = humanizeAgentId(id);
      }
    }

    const isDefault = existing?.default === true || id === "main";
    const sourceFile =
      typeof existing?.sourceFile === "string" && existing.sourceFile.trim()
        ? existing.sourceFile.trim()
        : null;
    agents.push({
      id,
      name: displayName,
      default: isDefault,
      sourceFile,
      workspace: `/home/node/.openclaw/workspace/agents/${id}`,
      folder: id,
    });
  }

  if (agents.length > 0 && !agents.some((item) => item.default)) {
    agents[0].default = true;
  }
  sortManifestAgents(agents);
  return agents;
}

async function ensureCleanDirectory(dirPath) {
  await fs.rm(dirPath, { recursive: true, force: true });
  await fs.mkdir(dirPath, { recursive: true });
}

async function splitAgents(options) {
  const sourceDir = path.resolve(options.sourceDir);
  const outputDir = path.resolve(options.outputDir);
  const manifestPath = options.manifest
    ? path.resolve(options.manifest)
    : path.join(outputDir, "manifest.json");
  const existingManifestAgents = await loadExistingManifestAgents(manifestPath);
  const sourceEqualsOutput = sourceDir === outputDir;

  let sourceEntries = [];
  try {
    sourceEntries = await fs.readdir(sourceDir, { withFileTypes: true });
  } catch {
    throw new Error(`Source directory does not exist: ${sourceDir}`);
  }

  const sourceFiles = sourceEntries
    .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith(".md"))
    .filter((entry) => !SKIP_FILENAMES.has(entry.name))
    .map((entry) => entry.name)
    .sort((left, right) => left.localeCompare(right));
  const mergedSourceFiles = sourceEqualsOutput ? [] : sourceFiles;

  const manifestAgents = [];
  if (mergedSourceFiles.length > 0) {
    await ensureCleanDirectory(outputDir);

    const seenIds = new Set();
    for (const fileName of mergedSourceFiles) {
      const sourcePath = path.join(sourceDir, fileName);
      const text = await fs.readFile(sourcePath, "utf8");
      const sections = extractSections(text, fileName);
      const stem = path.basename(fileName, path.extname(fileName));
      const { id, isDefault } = deriveAgentId(stem);
      if (seenIds.has(id)) {
        throw new Error(`Duplicate derived agent id '${id}' from file ${fileName}`);
      }
      seenIds.add(id);
      const name = deriveName(text, stem);

      const agentDir = path.join(outputDir, id);
      await fs.mkdir(agentDir, { recursive: true });

      for (const sectionName of SECTION_ORDER) {
        const outputName = OUTPUT_FILE_MAP[sectionName];
        const content = sections.get(sectionName) ?? "";
        await fs.writeFile(path.join(agentDir, outputName), content, "utf8");
      }

      manifestAgents.push({
        id,
        name,
        default: isDefault,
        sourceFile: fileName,
        workspace: `/home/node/.openclaw/workspace/agents/${id}`,
        folder: id,
      });
    }
    sortManifestAgents(manifestAgents);
  } else {
    const discoveredAgents = await buildManifestFromSplitDirectory(outputDir, existingManifestAgents);
    if (discoveredAgents.length === 0) {
      throw new Error(
        `No merged agent markdown files found in ${sourceDir} and no split agents found in ${outputDir}`,
      );
    }
    manifestAgents.push(...discoveredAgents);
  }

  const manifest = {
    version: 1,
    generatedAt: new Date().toISOString(),
    sourceDir,
    outputDir,
    agents: manifestAgents,
  };

  await fs.mkdir(path.dirname(manifestPath), { recursive: true });
  await fs.writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");

  if (!options.quiet) {
    process.stdout.write(`Split ${mergedSourceFiles.length} agent files into ${outputDir}\n`);
    process.stdout.write(`Manifest: ${manifestPath}\n`);
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  await splitAgents(options);
}

main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exit(1);
});

