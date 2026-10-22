#!/usr/bin/env python3
"""Match full Metal-layer FPS samples to completed tour signpost intervals."""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET


def rows(path):
    root = ET.parse(path).getroot()
    ids = {node.get('id'): node for node in root.iter() if node.get('id')}
    def resolve(node):
        while node.get('ref'):
            node = ids[node.get('ref')]
        return node
    names = None
    for table in root.findall('node'):
        schema = table.find('schema')
        if schema is not None:
            names = [col.findtext('mnemonic') for col in schema]
        if names is None:
            continue
        # xctrace can place all rows in a later schema-less table. Tables share the
        # preceding schema; duplicate signpost rows resolve to the same interval.
        for row in table.findall('row'):
            yield {name: resolve(node) for name, node in zip(names, row)}


def analyze(prefix):
    result = json.loads(Path(str(prefix) + '.json').read_text())
    pid = str(result['pid'])
    starts, intervals = {}, {}
    for row in rows(str(prefix) + '-signposts.xml'):
        process = row['process'].find('pid')
        if process is None or process.text != pid:
            continue
        name = row['name'].text
        if name not in ('Pan', 'GroundZoom', 'CameraZoom'):
            continue
        key = (name, row['identifier'].text)
        timestamp = int(row['time'].text) / 1e9
        if row['event-type'].text == 'Begin':
            starts[key] = timestamp
        elif row['event-type'].text == 'End' and key in starts:
            intervals[name] = (starts[key], timestamp)
    samples = []
    for row in rows(str(prefix) + '-fps.xml'):
        process = row['process'].find('pid')
        if process is None or process.text != pid or row['metric'].text != '0':
            continue
        if 'RealityKit' not in (row['layer-name'].text or ''):
            continue
        start = int(row['start'].text) / 1e9
        duration = int(row['duration'].text) / 1e9
        samples.append((start, start + duration, float(row['metric-value'].text), row['layer-id'].text))
    measured = []
    for name, (start, end) in intervals.items():
        # Full approximately one-second samples only; exclude boundary samples mixing idle/work.
        by_layer = {}
        for a, b, value, layer in samples:
            if a >= start and b <= end and 0.8 <= b - a <= 1.2:
                by_layer.setdefault(layer, []).append((value, b - a))
        for layer, values in by_layer.items():
            measured.append({'phase': name, 'startSeconds': start, 'endSeconds': end,
                'layerID': layer, 'sampleCount': len(values), 'samplesFPS': [v for v, _ in values],
                'meanFPS': sum(v * d for v, d in values) / sum(d for _, d in values),
                'minFPS': min(v for v, _ in values)})
    output = {'pid': result['pid'], 'method': 'Target PID RealityKit Metal layer; full 0.8–1.2 s samples inside phase signposts',
              'phases': measured, 'missingPhases': [p['phase'] for p in result['phases'] if not any(m['phase'] == p['phase'] for m in measured)]}
    Path(str(prefix) + '-analysis.json').write_text(json.dumps(output, indent=2) + '\n')
    print(json.dumps(output, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('prefix', type=Path)
    analyze(parser.parse_args().prefix)
