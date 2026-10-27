#!/usr/bin/env python3
"""Generate a large Markdown file for performance checks.  Usage: make_large.py OUT.md [sections=400]"""
import sys

out = sys.argv[1]
sections = int(sys.argv[2]) if len(sys.argv) > 2 else 400
langs = ['python', 'swift', 'javascript', 'bash', 'json', 'yaml', 'rust', 'go', 'sql', 'html']
parts = ['---\ntitle: Large document\ntags: [perf, test]\n---\n', '# Large document\n']
for i in range(sections):
    lang = langs[i % len(langs)]
    parts.append(f'\n## Section {i + 1}\n\n')
    parts.append('Paragraph with **bold**, *italic*, `code`, a [link](https://example.com/{0}), math $x_{0}^2$ and a footnote.[^{0}]\n\n'.format(i))
    parts.append('- item one\n- item two\n  - nested [[Section {0}]]\n- [x] done\n\n'.format(i))
    parts.append('| col a | col b | col c |\n|---|---|---|\n' + ''.join(f'| a{j} | b{j} | c{j} |\n' for j in range(5)) + '\n')
    parts.append(f'```{lang}\n' + ''.join(f'line_{j} = compute({j}) + "string"  # comment {j}\n' for j in range(25)) + '```\n\n')
    parts.append(f'> [!NOTE]\n> Callout number {i + 1}.\n\n')
    parts.append(f'[^{i}]: Footnote {i}.\n')
text = ''.join(parts)
open(out, 'w', encoding='utf-8').write(text)
print(f'{out}: {len(text.splitlines())} lines, {len(text) / 1024:.0f} KB')
