- script: |
    python3 << 'EOF'
import json

with open("sca-report.json") as f:
    data = json.load(f)

vulns = []

# Veracode SCA JSON usually stores issues inside dependencies
for dep in data.get("dependencies", []):
    for v in dep.get("vulnerabilities", []):
        vulns.append({
            "package": dep.get("name"),
            "version": dep.get("version"),
            "severity": v.get("severity"),
            "cve": v.get("cve"),
            "fix": v.get("fixedIn")
        })

html = """
<html>
<head>
<style>
table {border-collapse: collapse;}
th, td {border:1px solid #ccc;padding:6px;}
th {background:#eee;}
</style>
</head>
<body>
<h2>Veracode SCA Vulnerability Report</h2>
<table>
<tr>
<th>Package</th>
<th>Version</th>
<th>Severity</th>
<th>CVE</th>
<th>Fix Version</th>
</tr>
"""

for v in vulns:
    html += f"<tr><td>{v['package']}</td><td>{v['version']}</td><td>{v['severity']}</td><td>{v['cve']}</td><td>{v['fix']}</td></tr>"

html += "</table></body></html>"

with open("sca-report.html","w") as f:
    f.write(html)

print(f"Generated report with {len(vulns)} vulnerabilities")
EOF
  displayName: Generate SCA vulnerability HTML report
