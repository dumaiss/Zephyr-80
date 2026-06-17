#!/usr/bin/env python3
"""
kicad_nettrace.py — hierarchy-aware net tracer for KiCad .kicad_sch (v7/v8/v9 S-expression).

Pure stdlib. No KiCad install needed. Reads the schematic text directly and reconstructs
connectivity by geometry + labels, then FLATTENS the sheet hierarchy correctly:

  * wires connect by shared endpoints AND by a point lying on a segment (T-taps, mid-wire labels)
  * local labels connect within a sheet by name
  * global labels connect across the WHOLE design by name
  * power symbols (#PWR*, lib power:*) connect across the design by their net name (GND, +5V, ...)
  * HIERARCHY: a child sheet-pin connects to whatever the PARENT wires to that pin's location.
    It does NOT connect by name across sheets. (This is the thing a naive per-sheet tracer
    gets wrong: a parent can cross USR_UART_TX -> USR_UART_RX between two child sheets.)

It also:
  * tolerates the `(lib_name "X")` line that can appear before `(lib_id ...)` in an instance
  * parses each pin block atomically (reliable number / name / electrical-type)
  * auto-calibrates the symbol placement transform per sheet by wire-endpoint hit rate

Usage:
  python3 kicad_nettrace.py ROOT.kicad_sch                 # summary + hit rates
  python3 kicad_nettrace.py ROOT.kicad_sch --ref IC3       # pin -> net for a component
  python3 kicad_nettrace.py ROOT.kicad_sch --net SIO_MOSI  # all pins on a net
  python3 kicad_nettrace.py ROOT.kicad_sch --list-nets     # every net + members
  python3 kicad_nettrace.py ROOT.kicad_sch --check         # flag opens / driver-driver conflicts
  python3 kicad_nettrace.py ROOT.kicad_sch --csv out.csv   # dump ref,pin,name,etype,net
  python3 kicad_nettrace.py SHEET.kicad_sch --flat         # trace a single sheet, no hierarchy

Notes / limits:
  * Geometry-based: if a wire doesn't quite touch a pin, that pin reads as isolated. The hit-rate
    print tells you coverage; <100% usually means genuinely unused (no-connect) pins.
  * `(no_connect)` flags and ERC directives are not interpreted; an isolated pin is just isolated.
  * A child sheet used more than once is handled via per-instance paths.
  * Bus/bus-entry syntax (D[0..7]) is not expanded; name the individual members if you need them.
"""

import re, sys, os, argparse
from collections import defaultdict, deque

# ----------------------------------------------------------------------------- parsing
def read(fn):
    with open(fn, encoding="utf-8") as f:
        return f.read()

def parse_lib_pins(t):
    """base symbol name -> list of (unit, number, name, etype, px, py). Atomic per pin block."""
    out = defaultdict(list)
    m = re.search(r'\(lib_symbols\b(.*?)\n\t\)\n', t, re.S)
    seg_all = m.group(1) if m else ""
    for sm in re.finditer(r'\(symbol "([A-Za-z0-9_\-\.]+_(\d+)_(\d+))"', seg_all):
        full, unit = sm.group(1), int(sm.group(2))
        base = re.sub(r'_\d+_\d+$', '', full)
        start = sm.end()
        nxt = seg_all.find('(symbol "', start)
        body = seg_all[start: nxt if nxt > 0 else len(seg_all)]
        for blk in body.split('(pin ')[1:]:
            etype = blk.split(None, 1)[0]
            at = re.search(r'\(at ([\d\.\-]+) ([\d\.\-]+) (\d+)\)', blk)
            num = re.search(r'\(number "([^"]+)"', blk)
            nm = re.search(r'\(name "([^"]*)"', blk)
            if at and num:
                out[base].append((unit, num.group(1), nm.group(1) if nm else "",
                                  etype, float(at.group(1)), float(at.group(2))))
    return out

def parse_instances(t):
    """Placed component symbols (top-level). Handles optional (lib_name ...) before (lib_id ...)."""
    insts = []
    starts = [m.start() for m in re.finditer(r'\n\t\(symbol\n', t)]
    starts.append(len(t))
    for i in range(len(starts) - 1):
        body = t[starts[i]:starts[i + 1]]
        libid = re.search(r'\(lib_id "([^"]+)"\)', body)
        at = re.search(r'\n\t\t\(at ([\d\.\-]+) ([\d\.\-]+) (\d+)\)', body)
        if not (libid and at):
            continue
        libname = re.search(r'\(lib_name "([^"]+)"\)', body)
        mir = re.search(r'\(mirror (\w+)\)', body)
        un = re.search(r'\(unit (\d+)\)', body)
        ref = re.search(r'\(property "Reference" "([^"]+)"', body)
        val = re.search(r'\(property "Value" "([^"]+)"', body)
        uu = re.search(r'\(uuid "([^"]+)"\)', body)
        insts.append(dict(
            key=(libname.group(1) if libname else libid.group(1).split(':')[-1]),
            libid=libid.group(1).split(':')[-1],
            x=float(at.group(1)), y=float(at.group(2)), rot=int(at.group(3)),
            mir=mir.group(1) if mir else None, unit=int(un.group(1)) if un else 1,
            ref=ref.group(1) if ref else "?", val=val.group(1) if val else "",
            uuid=uu.group(1) if uu else ""))
    return insts

def parse_wires(t):
    return [((round(float(a), 2), round(float(b), 2)), (round(float(c), 2), round(float(d), 2)))
            for a, b, c, d in re.findall(
                r'\(wire\s*\(pts\s*\(xy ([\d\.\-]+) ([\d\.\-]+)\)\s*\(xy ([\d\.\-]+) ([\d\.\-]+)\)', t)]

def parse_labels(t):
    """(name, x, y, kind) with kind in {l=local, g=global, h=hierarchical}. Tolerates (shape ..) before (at ..)."""
    L = []
    for kind, code in [('label', 'l'), ('global_label', 'g'), ('hierarchical_label', 'h')]:
        for m in re.finditer(r'\(%s "([^"]+)"[\s\S]{0,120}?\(at ([\d\.\-]+) ([\d\.\-]+)' % kind, t):
            L.append((m.group(1), round(float(m.group(2)), 2), round(float(m.group(3)), 2), code))
    return L

def parse_sheets(t):
    """Hierarchical sheet instances on this sheet: dict(uuid, name, file, pins={name:(x,y)})."""
    out = []
    for blk in re.finditer(r'\(sheet\b[\s\S]*?\n\t\)', t):
        b = blk.group(0)
        name = re.search(r'\(property "Sheetname" "([^"]+)"', b)
        sfile = re.search(r'\(property "Sheetfile" "([^"]+)"', b)
        uu = re.search(r'\(uuid "([^"]+)"\)', b)
        pins = {}
        for pm in re.finditer(r'\(pin "([^"]+)" \w+\s*\(at ([\d\.\-]+) ([\d\.\-]+)', b):
            pins[pm.group(1)] = (round(float(pm.group(2)), 2), round(float(pm.group(3)), 2))
        if sfile:
            out.append(dict(uuid=uu.group(1) if uu else "",
                            name=name.group(1) if name else "?",
                            file=sfile.group(1), pins=pins))
    return out

# ----------------------------------------------------------------------------- geometry
def xform(px, py, rot, mir, conv):
    x, y = px, py
    if conv['baseflip']:
        y = -y
    if mir == 'x':
        y = -y
    if mir == 'y':
        x = -x
    r = rot % 360
    if conv['ccw']:
        if r == 90:   x, y = -y, x
        elif r == 180: x, y = -x, -y
        elif r == 270: x, y = y, -x
    else:
        if r == 90:   x, y = y, -x
        elif r == 180: x, y = -x, -y
        elif r == 270: x, y = -y, x
    return x, y

def pins_of(inst, libpins, conv):
    base = inst['key'] if inst['key'] in libpins else inst['libid']
    out = []
    for (unit, num, nm, et, px, py) in libpins.get(base, []):
        if unit not in (0, inst['unit']):
            continue
        dx, dy = xform(px, py, inst['rot'], inst['mir'], conv)
        out.append((num, nm, et, round(inst['x'] + dx, 2), round(inst['y'] + dy, 2)))
    return out

def calibrate(insts, libpins, W):
    wpts = set()
    for a, b in W:
        wpts.add(a); wpts.add(b)
    best = None
    for bf in (True, False):
        for ccw in (True, False):
            conv = dict(baseflip=bf, ccw=ccw)
            hit = tot = 0
            for inst in insts:
                for (_, _, _, x, y) in pins_of(inst, libpins, conv):
                    tot += 1
                    if (x, y) in wpts:
                        hit += 1
            if best is None or hit > best[0]:
                best = (hit, tot, conv)
    return best  # (hit, tot, conv)

# ----------------------------------------------------------------------------- union-find
class UF:
    def __init__(self): self.p = {}
    def find(self, a):
        self.p.setdefault(a, a)
        root = a
        while self.p[root] != root:
            root = self.p[root]
        while self.p[a] != root:
            self.p[a], a = root, self.p[a]
        return root
    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.p[ra] = rb

def on_seg(p, a, b, tol=0.03):
    (px, py), (ax, ay), (bx, by) = p, a, b
    if px < min(ax, bx) - tol or px > max(ax, bx) + tol: return False
    if py < min(ay, by) - tol or py > max(ay, by) + tol: return False
    cross = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
    L = ((bx - ax) ** 2 + (by - ay) ** 2) ** 0.5 or 1
    return abs(cross) / L < tol

POWER_RE = re.compile(r'^#PWR')

def build_sheet(t):
    """Parse + connect one sheet's geometry. Returns a record used by the flattener."""
    libpins = parse_lib_pins(t)
    insts = parse_instances(t)
    W = parse_wires(t)
    Lb = parse_labels(t)
    sheets = parse_sheets(t)
    hit, tot, conv = calibrate(insts, libpins, W)

    uf = UF()
    nodes = set()
    for a, b in W:
        uf.union(a, b); nodes.add(a); nodes.add(b)

    pin_at = defaultdict(list)   # coord -> [(ref, num, name, etype, is_power, val)]
    for inst in insts:
        is_pwr = bool(POWER_RE.match(inst['ref']))
        for (num, nm, et, x, y) in pins_of(inst, libpins, conv):
            pin_at[(x, y)].append((inst['ref'], num, nm, et, is_pwr, inst['val']))
            nodes.add((x, y))

    lab_at = defaultdict(list)   # coord -> [(name, kind)]
    name_pts = defaultdict(list)  # local-label name -> [coord]   (intra-sheet name merge)
    for nm, x, y, k in Lb:
        lab_at[(x, y)].append((nm, k)); nodes.add((x, y))
        if k == 'l':              # local labels merge within the sheet by name
            name_pts[nm].append((x, y))
    # sheet-pin locations are nodes too (for the parent side of hierarchy)
    for sh in sheets:
        for nm, (x, y) in sh['pins'].items():
            nodes.add((x, y))

    nodes = list(nodes)
    for (a, b) in W:                 # mid-wire taps (labels/pins sitting on a segment)
        for p in nodes:
            if p != a and p != b and on_seg(p, a, b):
                uf.union(p, a)
    for nm, pts in name_pts.items():
        for p in pts[1:]:
            uf.union(pts[0], p)

    return dict(uf=uf, pin_at=pin_at, lab_at=lab_at, sheets=sheets,
                hit=hit, tot=tot, conv=conv, insts=insts)

# ----------------------------------------------------------------------------- hierarchy flatten
def _resolve(fname, root_dir):
    """Find a sheet file, tolerating space<->underscore differences in the Sheetfile property."""
    cands = [fname, fname.replace(' ', '_'), fname.replace('_', ' ')]
    for c in cands:
        p = c if os.path.isabs(c) else os.path.join(root_dir, c)
        if os.path.exists(p):
            return p
    return fname if os.path.isabs(fname) else os.path.join(root_dir, fname)

def trace(root_file):
    """Walk the hierarchy from root_file. Returns (guf, node_pins, node_labels, sheet_info).

    Nodes are keyed (path, coord) where path is a tuple of sheet-instance uuids ((), then
    (uuid,), then (uuid, child_uuid), ...). Cross-sheet links are made via parent sheet-pin
    wiring (correct) plus global-label name and power-net name (design-wide)."""
    root_dir = os.path.dirname(os.path.abspath(root_file))
    guf = UF()
    node_pins = defaultdict(list)     # (path,coord) -> [(ref, num, name, etype, is_power, val)]
    node_labels = defaultdict(list)   # (path,coord) -> [(name, kind)]
    global_pts = defaultdict(list)    # global-label name -> [(path,coord)]
    power_pts = defaultdict(list)     # power net name   -> [(path,coord)]
    sheet_info = []                   # (path, name, file, hit, tot, conv)

    def walk(fname, path, dispname):
        fname = _resolve(fname, root_dir)
        if not os.path.exists(fname):
            sys.stderr.write(f"  [warn] missing sheet file: {fname}\n")
            return
        rec = build_sheet(read(fname))
        sheet_info.append((path, dispname, os.path.basename(fname), rec['hit'], rec['tot'], rec['conv']))

        # seed nodes into the global UF and indexes
        for coord, plist in rec['pin_at'].items():
            n = (path, coord)
            for x in plist:
                node_pins[n].append(x)
                if x[4]:                              # is_power -> name by Value (GND/+5V/...)
                    power_pts[x[5] or x[2]].append(n)
            guf.union(n, n)
        for coord, labs in rec['lab_at'].items():
            n = (path, coord)
            for nm, k in labs:
                node_labels[n].append((nm, k))
                if k == 'g':
                    global_pts[nm].append(n)
            guf.union(n, n)
        # carry intra-sheet unions into the global UF
        for coord in list(rec['pin_at'].keys()) + list(rec['lab_at'].keys()):
            r = rec['uf'].find(coord)
            guf.union((path, coord), (path, r))
        for sh in rec['sheets']:
            for nm, coord in sh['pins'].items():
                r = rec['uf'].find(coord)
                guf.union((path, coord), (path, r))

        # recurse + stitch each child sheet instance
        for sh in rec['sheets']:
            child_path = path + (sh['uuid'],)
            cfile = sh['file']
            cabs = _resolve(cfile, root_dir)
            # need the child's hierarchical-label coordinates to bind to parent sheet pins
            child_hier = {}
            if os.path.exists(cabs):
                for nm, x, y, k in parse_labels(read(cabs)):
                    if k == 'h':
                        child_hier.setdefault(nm, (x, y))
            walk(cfile, child_path, sh['name'])
            # bind: parent sheet-pin 'nm' (at parent coord) <-> child hier-label 'nm'
            for nm, pcoord in sh['pins'].items():
                ccoord = child_hier.get(nm)
                if ccoord is not None:
                    guf.union((path, pcoord), (child_path, ccoord))

    walk(root_file, (), os.path.basename(root_file))

    # design-wide merges: global labels by name, power nets by name
    for nm, pts in global_pts.items():
        for p in pts[1:]:
            guf.union(pts[0], p)
    for nm, pts in power_pts.items():
        for p in pts[1:]:
            guf.union(pts[0], p)

    return guf, node_pins, node_labels, sheet_info, power_pts

def netname(labels, is_power_root=None):
    g = sorted({n for n, k in labels if k == 'g'})
    h = sorted({n for n, k in labels if k == 'h'})
    l = sorted({n for n, k in labels if k == 'l'})
    for grp in (g, l, h):
        if grp:
            return "/".join(grp)
    return None

def collect_nets(guf, node_pins, node_labels, power_pts):
    """root -> dict(labels=set, pins=set, power=set)."""
    nets = defaultdict(lambda: {'labels': set(), 'pins': set(), 'power': set()})
    for n, plist in node_pins.items():
        r = guf.find(n)
        for ref, num, nm, et, ispwr, val in plist:
            if ispwr:
                nets[r]['power'].add(val or nm)
            else:
                nets[r]['pins'].add((n[0], ref, num, nm, et))
    for n, labs in node_labels.items():
        r = guf.find(n)
        for nm, k in labs:
            nets[r]['labels'].add((nm, k))
    return nets

def net_label(net):
    nm = netname(net['labels'])
    if nm:
        return nm
    if net['power']:
        return "/".join(sorted(net['power']))
    return "(unnamed)"

def fmt_pins(net):
    def pp(p):
        path, ref, num, nm, et = p
        return f"{ref}.{num}" + (f"({nm})" if nm and nm != num else "")
    return ", ".join(sorted({pp(p) for p in net['pins']}))

# ----------------------------------------------------------------------------- CLI
def main():
    ap = argparse.ArgumentParser(description="Hierarchy-aware KiCad .kicad_sch net tracer")
    ap.add_argument("schematic")
    ap.add_argument("--ref", help="show pin->net for this component reference")
    ap.add_argument("--net", help="show all pins on this net name")
    ap.add_argument("--list-nets", action="store_true")
    ap.add_argument("--check", action="store_true", help="flag isolated pins and driver-driver conflicts")
    ap.add_argument("--csv", help="write full netlist to CSV")
    ap.add_argument("--flat", action="store_true", help="trace only this sheet (ignore hierarchy)")
    args = ap.parse_args()

    if args.flat:
        rec = build_sheet(read(args.schematic))
        guf = UF()
        node_pins = defaultdict(list); node_labels = defaultdict(list); power_pts = defaultdict(list)
        for coord, plist in rec['pin_at'].items():
            for x in plist:
                node_pins[((), coord)].append(x)
                if x[4]: power_pts[x[5] or x[2]].append(((), coord))
        for coord, labs in rec['lab_at'].items():
            for nm, k in labs: node_labels[((), coord)].append((nm, k))
        # intra-sheet unions
        allc = set(rec['pin_at']) | set(rec['lab_at'])
        for c in allc: guf.union(((), c), ((), rec['uf'].find(c)))
        name_pts = defaultdict(list)
        for n, labs in node_labels.items():
            for nm, k in labs:
                if k == 'l': name_pts[nm].append(n)
                if k == 'g': power_pts  # no-op
        for nm, pts in name_pts.items():
            for p in pts[1:]: guf.union(pts[0], p)
        sheet_info = [((), os.path.basename(args.schematic), os.path.basename(args.schematic),
                       rec['hit'], rec['tot'], rec['conv'])]
    else:
        guf, node_pins, node_labels, sheet_info, power_pts = trace(args.schematic)

    nets = collect_nets(guf, node_pins, node_labels, power_pts)

    if not (args.ref or args.net or args.list_nets or args.check or args.csv):
        print(f"Schematic: {args.schematic}")
        print("Sheets (coverage = pin endpoints landing on a wire):")
        for path, name, f, hit, tot, conv in sheet_info:
            pct = (100 * hit / tot) if tot else 0
            print(f"  {name:24} {f:28} {hit:>4}/{tot:<4} ({pct:4.0f}%)  transform={conv}")
        npins = sum(len(n['pins']) for n in nets.values())
        print(f"\nNets: {len([n for n in nets.values() if n['pins']])}   placed pins: {npins}")
        print("Run with --list-nets, --ref REF, --net NAME, --check, or --csv out.csv")
        return

    if args.list_nets:
        rows = [(net_label(n), fmt_pins(n)) for n in nets.values() if n['pins']]
        for lbl, mem in sorted(rows):
            print(f"[{lbl}]  {mem}")
        return

    if args.ref:
        found = []
        for n in nets.values():
            ps = [p for p in n['pins'] if p[1] == args.ref]
            for p in ps:
                found.append((int(p[2]) if p[2].isdigit() else 999, p[2], p[3], p[4], net_label(n)))
        for _, num, nm, et, lbl in sorted(found):
            print(f"  pin {num:>3} {nm:14} {et:10} -> {lbl}")
        if not found:
            print(f"  (no pins found for {args.ref})")
        return

    if args.net:
        for n in nets.values():
            if net_label(n) == args.net:
                print(f"[{args.net}]  {fmt_pins(n)}")
                return
        print(f"(no net named {args.net})")
        return

    if args.check:
        print("# Isolated pins (no connection found — usually intentional no-connects):")
        for n in nets.values():
            if len(n['pins']) == 1 and not n['power'] and not n['labels']:
                p = next(iter(n['pins']))
                print(f"  {p[1]}.{p[2]}({p[3]})")
        print("\n# Driver-driver conflicts (>=2 output pins on one net):")
        for n in nets.values():
            outs = [p for p in n['pins'] if p[4] == 'output']
            if len(outs) >= 2:
                print(f"  [{net_label(n)}]  " + ", ".join(f"{p[1]}.{p[2]}({p[3]})" for p in outs))
        print("\n# Input-only nets (no driver: all pins are inputs, no label/power):")
        for n in nets.values():
            if n['pins'] and not n['power'] and not any(k == 'g' for _, k in n['labels']):
                kinds = {p[4] for p in n['pins']}
                if kinds and kinds <= {'input'} and len(n['pins']) >= 2:
                    print(f"  [{net_label(n)}]  " + ", ".join(f"{p[1]}.{p[2]}({p[3]})" for p in n['pins']))
        return

    if args.csv:
        import csv
        with open(args.csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["net", "ref", "pin", "pin_name", "etype"])
            for n in nets.values():
                lbl = net_label(n)
                for path, ref, num, nm, et in sorted(n['pins']):
                    w.writerow([lbl, ref, num, nm, et])
        print(f"wrote {args.csv}")
        return

if __name__ == "__main__":
    main()
