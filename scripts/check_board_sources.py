"""Cross-check used pins and MII interface against official Digilent files.

Pass --download to refresh evidence (network required). These checks do not
replace schematic/PHY timing review or physical-board validation.
"""
import argparse
import hashlib
from pathlib import Path
import re
import urllib.request
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
SOURCES={
    'Arty-A7-100-Master.xdc':'https://raw.githubusercontent.com/Digilent/digilent-xdc/master/Arty-A7-100-Master.xdc',
    'board.xml':'https://raw.githubusercontent.com/Digilent/vivado-boards/master/new/board_files/arty-a7-100/E.0/1.1/board.xml',
}


def pins(text):
    return dict((name,pin) for pin,name in re.findall(
        r'PACKAGE_PIN\s+(\w+)[^\n]*?get_ports\s+\{?\s*(\w+(?:\[\d+\])?)',text))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--download',action='store_true')
    args=parser.parse_args()
    directory=ROOT/'build'/'sources'
    directory.mkdir(parents=True,exist_ok=True)
    for name,url in SOURCES.items():
        path=directory/name
        if args.download:
            with urllib.request.urlopen(url,timeout=30) as response:
                path.write_bytes(response.read())
        if not path.exists():
            raise SystemExit(f'Missing {name}; run with --download')
        print(name,hashlib.sha256(path.read_bytes()).hexdigest(),url)
    official=pins((directory/'Arty-A7-100-Master.xdc').read_text())
    actual=pins((ROOT/'constraints/arty_a7_100t.xdc').read_text())
    for port,pin in actual.items():
        expected='ck_rst' if port=='reset_n' else port
        assert official.get(expected)==pin,(port,pin,official.get(expected))
    assert len(actual)==19,len(actual)
    tree=ET.parse(directory/'board.xml')
    interface=tree.find(".//interface[@name='eth_mii']")
    assert interface is not None and interface.attrib['type']=='xilinx.com:interface:mii_rtl:1.0'
    signals={p.attrib['logical_port'] for p in interface.findall('.//port_map')}
    assert {'RX_CLK','TX_CLK','RXD','TXD','RX_DV','RX_ER','TX_EN','RST_N'}<=signals
    print('PASS: 19 board pins match official Digilent XDC; board XML confirms MII with independent RX/TX clocks')


if __name__=='__main__':main()
