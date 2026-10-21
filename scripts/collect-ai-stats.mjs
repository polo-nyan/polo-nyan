#!/usr/bin/env node
// collect-ai-stats.mjs — gather AI pair-programming statistics into ai-stats.json.
//
// Runs identically on a developer box and inside the daily workflow:
//   GH_TOKEN=... node scripts/collect-ai-stats.mjs [out.json]
//
// Data (all from the GitHub API, nothing estimated):
//   * every commit authored by the owner on the default branch of every repo
//     the owner can see (personal + org, public + private), last 12 months:
//     date, message trailers, additions, deletions
//   * merged pull requests (last 40 per repo, bot authors excluded): created
//     and merged timestamps, head-commit CI rollup, and whether any commit in
//     the PR carries an AI co-author trailer
//
// Output is aggregate only: public repos are named, private repos are rolled
// up into one row. Exits non-zero on a missing token, an empty repo list or a
// GraphQL error, so a broken run never silently writes an empty file.

import { writeFileSync } from 'node:fs';

const OWNER = process.env.PROFILE_OWNER || 'polo-nyan';
const ORG = process.env.PROFILE_ORG || 'smol-kitten';
const OUT = process.argv[2] || 'ai-stats.json';
const TOKEN = process.env.GH_TOKEN || process.env.GITHUB_TOKEN;
const WINDOW_DAYS = 365;
const PRS_PER_REPO = 40;
const COMMITS_PER_PR = 60;

if (!TOKEN) { console.error('❌ GH_TOKEN / GITHUB_TOKEN is required'); process.exit(1); }

const API = 'https://api.github.com';
const headers = { Authorization: `Bearer ${TOKEN}`, 'User-Agent': 'polo-nyan-profile-stats', Accept: 'application/vnd.github+json' };

async function rest(path) {
  const r = await fetch(API + path, { headers });
  if (!r.ok) throw new Error(`REST ${path} -> ${r.status} ${await r.text()}`);
  return r.json();
}

async function graphql(query, variables) {
  for (let attempt = 1; attempt <= 3; attempt++) {
    const r = await fetch(API + '/graphql', { method: 'POST', headers, body: JSON.stringify({ query, variables }) });
    if (r.status === 502 || r.status === 503) { await new Promise(res => setTimeout(res, 2000 * attempt)); continue; }
    const j = await r.json();
    if (j.errors && !j.data) throw new Error('GraphQL: ' + JSON.stringify(j.errors).slice(0, 500));
    if (j.errors) console.error('⚠️  partial GraphQL errors: ' + JSON.stringify(j.errors).slice(0, 300));
    return j.data;
  }
  throw new Error('GraphQL: repeated 5xx');
}

// --- AI trailer classification (same rules as update-stats.yml) ------------
const COAUTHOR_RE = /^[ \t]*co-authored-by:[ \t]*(.+?)[ \t]*<([^>]*)>[ \t]*$/gim;
function hasAITrailer(message) {
  COAUTHOR_RE.lastIndex = 0;
  let m;
  while ((m = COAUTHOR_RE.exec(message || '')) !== null) {
    const hay = (m[1] + ' ' + m[2]).toLowerCase();
    if (/@(.*\.)?anthropic\.com$/.test(m[2].toLowerCase())) return true;
    if (/\b(claude|anthropic|opus|sonnet|haiku|fable)\b/.test(hay)) return true;
    if (/\b(copilot|chatgpt|openai|gpt-?\d|cursor|codeium|gemini|devin|codex|tabnine|aider)\b/.test(hay)) return true;
  }
  return false;
}

const since = new Date(Date.now() - WINDOW_DAYS * 86400e3);
const sinceISO = since.toISOString();
const monthKey = d => d.slice(0, 7);
function weekKey(iso) {           // ISO-8601 week, "YYYY-Www"
  const d = new Date(iso); d.setUTCHours(0, 0, 0, 0);
  d.setUTCDate(d.getUTCDate() + 3 - ((d.getUTCDay() + 6) % 7));
  const y = d.getUTCFullYear();
  const w = Math.ceil(((d - Date.UTC(y, 0, 4)) / 86400e3 + ((new Date(Date.UTC(y, 0, 4)).getUTCDay() + 6) % 7) + 1) / 7);
  return `${y}-W${String(w).padStart(2, '0')}`;
}
const median = a => { if (!a.length) return null; const s = [...a].sort((x, y) => x - y); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
const mean = a => a.length ? a.reduce((x, y) => x + y, 0) / a.length : null;
const pct = (n, d) => d ? +((n / d) * 100).toFixed(1) : 0;
const r1 = x => x == null ? null : +x.toFixed(1);

// --- 1. repositories ---------------------------------------------------------
const viewer = await graphql('{ viewer { id login } }');
if (viewer.viewer.login !== OWNER) console.error(`⚠️  token belongs to ${viewer.viewer.login}, expected ${OWNER}; commits are filtered by the token owner`);
const authorId = viewer.viewer.id;

let repos = [];
for (let page = 1; ; page++) {
  const batch = await rest(`/user/repos?per_page=100&page=${page}&affiliation=owner,organization_member&visibility=all`);
  repos = repos.concat(batch);
  if (batch.length < 100) break;
}
repos = repos.filter(r => (r.owner.login === OWNER || r.owner.login === ORG) && new Date(r.pushed_at) >= since);
if (repos.length === 0) { console.error('❌ no repositories pushed in the window; refusing to write empty stats'); process.exit(1); }
console.error(`📚 ${repos.length} repos pushed in the last ${WINDOW_DAYS} days`);

// --- 2. commits + PRs per repo ------------------------------------------------
const HISTORY_Q = `query($owner:String!,$name:String!,$since:GitTimestamp!,$after:String,$author:ID!){
  repository(owner:$owner,name:$name){ defaultBranchRef { target { ... on Commit {
    history(first:100, since:$since, after:$after, author:{id:$author}) {
      pageInfo { hasNextPage endCursor }
      nodes { committedDate message additions deletions }
    } } } } } }`;
const PR_Q = `query($owner:String!,$name:String!,$n:Int!,$c:Int!){
  repository(owner:$owner,name:$name){ pullRequests(last:$n, states:MERGED) { nodes {
    createdAt mergedAt additions deletions author { login }
    all: commits(first:$c) { totalCount nodes { commit { message } } }
    head: commits(last:1) { nodes { commit { statusCheckRollup { state } } } }
  } } } }`;

const monthly = {}, weekly = {}, repoRows = [], prs = [];
let totalCommits = 0;
const bump = (map, k, c) => { const e = map[k] || (map[k] = { commits: 0, ai: 0, additions: 0, deletions: 0, aiAdditions: 0, aiDeletions: 0 }); e.commits++; e.additions += c.additions; e.deletions += c.deletions; if (c.ai) { e.ai++; e.aiAdditions += c.additions; e.aiDeletions += c.deletions; } };

for (const repo of repos) {
  const row = { name: repo.name, owner: repo.owner.login, url: repo.html_url, public: !repo.private, fork: !!repo.fork, archived: !!repo.archived, commits: 0, ai: 0, additions: 0, deletions: 0 };
  let after = null;
  for (let page = 0; page < 30; page++) {
    const d = await graphql(HISTORY_Q, { owner: repo.owner.login, name: repo.name, since: sinceISO, after, author: authorId });
    const h = d?.repository?.defaultBranchRef?.target?.history;
    if (!h) break;
    for (const c of h.nodes) {
      const rec = { ai: hasAITrailer(c.message), additions: c.additions || 0, deletions: c.deletions || 0 };
      totalCommits++; row.commits++; row.additions += rec.additions; row.deletions += rec.deletions; if (rec.ai) row.ai++;
      bump(monthly, monthKey(c.committedDate), rec); bump(weekly, weekKey(c.committedDate), rec);
    }
    if (!h.pageInfo.hasNextPage) break;
    after = h.pageInfo.endCursor;
  }
  const p = await graphql(PR_Q, { owner: repo.owner.login, name: repo.name, n: PRS_PER_REPO, c: COMMITS_PER_PR });
  for (const pr of (p?.repository?.pullRequests?.nodes || [])) {
    if (!pr.mergedAt || new Date(pr.mergedAt) < since) continue;
    const login = pr.author?.login || '';
    if (login.endsWith('[bot]') || login === 'dependabot' || login === 'github-actions') continue;
    const ai = pr.all.nodes.some(n => hasAITrailer(n.commit.message));
    const hours = (new Date(pr.mergedAt) - new Date(pr.createdAt)) / 3600e3;
    const ci = pr.head.nodes[0]?.commit?.statusCheckRollup?.state || null;   // SUCCESS | FAILURE | ERROR | PENDING | EXPECTED | null
    prs.push({ ai, hours, ci, commits: pr.all.totalCount, additions: pr.additions, deletions: pr.deletions, truncated: pr.all.totalCount > COMMITS_PER_PR });
  }
  if (row.commits > 0) repoRows.push(row);
  console.error(`  ${repo.owner.login}/${repo.name}: ${row.commits} commits, ${row.ai} AI`);
}

if (totalCommits === 0) { console.error('❌ no commits found in the window; refusing to write empty stats'); process.exit(1); }

// --- 3. aggregate -------------------------------------------------------------
const series = map => Object.keys(map).sort().map(k => ({ period: k, ...map[k], share: pct(map[k].ai, map[k].commits) }));
const prGroup = sel => {
  const g = prs.filter(sel); const withCI = g.filter(p => p.ci === 'SUCCESS' || p.ci === 'FAILURE' || p.ci === 'ERROR');
  return { count: g.length, medianMergeHours: r1(median(g.map(p => p.hours))), meanMergeHours: r1(mean(g.map(p => p.hours))),
           medianCommits: median(g.map(p => p.commits)), ciChecked: withCI.length, ciPassed: withCI.filter(p => p.ci === 'SUCCESS').length,
           ciPassRate: pct(withCI.filter(p => p.ci === 'SUCCESS').length, withCI.length),
           medianLinesChanged: median(g.map(p => p.additions + p.deletions)) };
};
const sumRows = rows => rows.reduce((a, r) => ({ commits: a.commits + r.commits, ai: a.ai + r.ai, additions: a.additions + r.additions, deletions: a.deletions + r.deletions }), { commits: 0, ai: 0, additions: 0, deletions: 0 });
const publicRows = repoRows.filter(r => r.public && !r.fork && !r.archived).sort((a, b) => b.commits - a.commits)
  .map(r => ({ name: r.name, owner: r.owner, url: r.url, commits: r.commits, ai: r.ai, share: pct(r.ai, r.commits), additions: r.additions, deletions: r.deletions }));
const privateRows = repoRows.filter(r => !(r.public && !r.fork && !r.archived));
const priv = sumRows(privateRows);
const all = sumRows(repoRows);
const aiCommits = repoRows.reduce((s, r) => s + r.ai, 0);
const lines = {
  ai: { commits: aiCommits, additions: Object.values(monthly).reduce((s, m) => s + m.aiAdditions, 0), deletions: Object.values(monthly).reduce((s, m) => s + m.aiDeletions, 0) },
  human: { commits: totalCommits - aiCommits, additions: all.additions - Object.values(monthly).reduce((s, m) => s + m.aiAdditions, 0), deletions: all.deletions - Object.values(monthly).reduce((s, m) => s + m.aiDeletions, 0) },
};
for (const g of Object.values(lines)) g.perCommit = g.commits ? Math.round((g.additions + g.deletions) / g.commits) : 0;

const out = {
  generatedAt: new Date().toISOString().slice(0, 10),
  window: { since: sinceISO.slice(0, 10), until: new Date().toISOString().slice(0, 10), days: WINDOW_DAYS },
  reposScanned: repos.length, reposWithCommits: repoRows.length,
  totals: { commits: totalCommits, ai: aiCommits, share: pct(aiCommits, totalCommits), additions: all.additions, deletions: all.deletions },
  monthly: series(monthly),
  weekly: series(weekly),
  repos: { public: publicRows, private: { repos: privateRows.length, ...priv, share: pct(priv.ai, priv.commits) } },
  prs: { sampled: prs.length, perRepoCap: PRS_PER_REPO, truncatedCommitLists: prs.filter(p => p.truncated).length, ai: prGroup(p => p.ai), human: prGroup(p => !p.ai) },
  lines,
};
writeFileSync(OUT, JSON.stringify(out, null, 2) + '\n');
console.error(`✅ wrote ${OUT}: ${totalCommits} commits (${out.totals.share}% AI), ${prs.length} PRs, ${publicRows.length} public repos named`);
