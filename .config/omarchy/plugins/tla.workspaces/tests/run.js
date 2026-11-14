// node tests/run.js : unit tests for WorkspaceModel.js (strips the QML .pragma line)
const fs = require('fs'), path = require('path'), assert = require('assert');
const src = fs.readFileSync(path.join(__dirname, '..', 'WorkspaceModel.js'), 'utf8').replace(/^\.pragma.*$/m, '');
const M = new Function(src + '; return { parseSlots, parseMode, placement, label, slotIndex };')();
const slots = M.parseSlots('0\tAOC A\n1\tAOC B\n2\tAOC C\n3\tAOC D\n');
let n = 0; const t = (name, fn) => { fn(); n++; };
t('parse', () => assert.deepStrictEqual(slots, { 0: 'AOC A', 1: 'AOC B', 2: 'AOC C', 3: 'AOC D' }));
t('parse junk', () => assert.deepStrictEqual(M.parseSlots('x\tA\n-1\tB\n\n2\t\n1.5\tC\n4\t<b>X</b>'), { 4: '<b>X</b>' }));
t('mode default', () => { assert.strictEqual(M.parseMode(''), 'decade'); assert.strictEqual(M.parseMode('split\n'), 'split'); });
t('slot index', () => { assert.strictEqual(M.slotIndex(10, 10), 0); assert.strictEqual(M.slotIndex(11, 10), 1); assert.strictEqual(M.slotIndex(40, 10), 3); });
t('home', () => assert.strictEqual(M.placement(22, 'AOC C', slots, 'decade', ['AOC A', 'AOC C']).displaced, false));
t('borrowed, owner gone', () => assert.deepStrictEqual(M.placement(12, 'AOC C', slots, 'decade', ['AOC A', 'AOC C']), { displaced: true, owner: 'AOC B', ownerConnected: false }));
t('moved, owner present', () => assert.deepStrictEqual(M.placement(12, 'AOC C', slots, 'decade', ['AOC B', 'AOC C']), { displaced: true, owner: 'AOC B', ownerConnected: true }));
t('split never displaced', () => assert.strictEqual(M.placement(12, 'AOC C', slots, 'split', []).displaced, false));
t('no slot', () => assert.strictEqual(M.placement(55, 'AOC C', slots, 'decade', []).displaced, false));
t('unknown host', () => assert.strictEqual(M.placement(12, '', slots, 'decade', []).displaced, false));
t('labels', () => { assert.strictEqual(M.label(11, false), '1'); assert.strictEqual(M.label(20, false), '0'); assert.strictEqual(M.label(12, true), '12'); });
console.log(`ok ${n} tests`);
