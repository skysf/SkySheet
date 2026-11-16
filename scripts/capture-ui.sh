#!/usr/bin/env bash
# 标准截图集自己生成输入；固定外观、选区和缩放，输出只写新目录。
# 用法：scripts/capture-ui.sh APP 新输出目录 [--appearance aqua|dark]
set -euo pipefail
cd "$(dirname "$0")/.."
APP=$1
OUTPUT=$2
APPEARANCE=aqua
if [[ $# -gt 2 ]]; then
  [[ $# == 4 && $3 == --appearance && ( $4 == aqua || $4 == dark ) ]] || exit 2
  APPEARANCE=$4
fi
mkdir "${OUTPUT}"
INPUTS="${OUTPUT}/inputs"
mkdir "${INPUTS}"
for kind in data formulas styles; do
  "${APP}" --benchmark "synthetic:${kind}" --benchmark-scale 0.01 --benchmark-only generate \
    --benchmark-file "${INPUTS}/${kind}.xlsx" > "${OUTPUT}/generate-${kind}.log" 2>&1
done
# 这三张极小边界表不需要保存成长期 Fixture；固定 XML 让前后版本读到完全相同的输入。
python3 - "${INPUTS}" <<'PY'
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import sys
output = Path(sys.argv[1])
ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
pkg = 'http://schemas.openxmlformats.org/package/2006/relationships'
for name in ['merge', 'center', 'extent']:
    cell_format = ' horizontal="center"' if name == 'center' else ''
    style = f'<styleSheet xmlns="{ns}"><fonts count="1"><font><sz val="11"/><name val="Helvetica"/></font></fonts><borders count="1"><border>' + (''.join(f'<{edge} style="thin"><color rgb="FF000000"/></{edge}>' for edge in ['left','right','top','bottom']) if name == 'merge' else '') + f'</border></borders><cellXfs count="1"><xf fontId="0" borderId="0"><alignment{cell_format}/></xf></cellXfs></styleSheet>'
    views = '<sheetViews><sheetView workbookViewId="0"><pane xSplit="1" ySplit="1" state="frozen" topLeftCell="B2"/></sheetView></sheetViews>' if name == 'merge' else ''
    cols = '<cols><col min="1" max="1" width="5" customWidth="1"/><col min="2" max="2" width="15" customWidth="1"/><col min="3" max="3" width="5" customWidth="1"/></cols>' if name == 'center' else ''
    data = '<row r="1"><c r="A1"><v>1</v></c></row>'
    if name == 'center':
        data = ''.join(f'<row r="{row}"><c r="{col}{row}" t="inlineStr"><is><t>MMMMMMMMMMMM</t></is></c></row>' for row, col in [(2, 'A'), (4, 'C'), (6, 'C')])
    merges = '<mergeCells count="3"><mergeCell ref="A1:C3"/><mergeCell ref="E1:E4"/><mergeCell ref="A5:C5"/></mergeCells>' if name == 'merge' else ''
    parts = {
        '[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>',
        '_rels/.rels': f'<Relationships xmlns="{pkg}"><Relationship Id="r1" Type="{rel}/officeDocument" Target="xl/workbook.xml"/></Relationships>',
        'xl/workbook.xml': f'<workbook xmlns="{ns}" xmlns:r="{rel}"><sheets><sheet name="Main" sheetId="1" r:id="r1"/></sheets></workbook>',
        'xl/_rels/workbook.xml.rels': f'<Relationships xmlns="{pkg}"><Relationship Id="r1" Type="{rel}/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="r2" Type="{rel}/styles" Target="styles.xml"/></Relationships>',
        'xl/styles.xml': style,
        'xl/worksheets/sheet1.xml': f'<worksheet xmlns="{ns}">{views}{cols}<sheetData>{data}</sheetData>{merges}</worksheet>',
    }
    with ZipFile(output / f'{name}.xlsx', 'x', ZIP_DEFLATED) as z:
        for path, xml in parts.items(): z.writestr(path, xml)
PY
capture() {
  "${APP}" --snapshot-input "${INPUTS}/$1.xlsx" --snapshot-output "${OUTPUT}/$2.png" --select "$3" \
    --appearance "${APPEARANCE}" "${@:4}" > "${OUTPUT}/$2.log" 2>&1
}
for kind in data formulas styles; do capture "${kind}" "${kind}-K60" K60; done
capture data data-A1 A1
capture data data-range A1:D8 --zoom 1.37
capture merge merge-top B2
capture merge merge-scroll E3
capture center center A1
capture extent extent-AA1 AA1
capture extent extent-A101 A101
capture extent extent-AZ201 AZ201
