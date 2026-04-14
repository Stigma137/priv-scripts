kubectl get ingress -A -o json | jq -r '
.items[] |
{
  namespace: .metadata.namespace,
  name: .metadata.name,
  cors: .metadata.annotations["nginx.ingress.kubernetes.io/cors-allow-origin"]
}'

kubectl get ingress -A \
-o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,ANNOTATION:.metadata.annotations.nginx\.ingress\.kubernetes\.io/proxy-read-timeout"

import json

with open("sca-report.json") as f:
    data = json.load(f)

print("records length:", len(data["records"]))

for record in data["records"]:
    vulns = record.get("vulnerabilities", [])
    print("vulnerabilities found:", len(vulns))

    for v in vulns:
        print("VULN:", v.get("name"), v.get("cve"))

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


- script: |
    SUMMARY="$(Build.ArtifactStagingDirectory)/sca-summary.md"

    REPORT_URL="$(System.CollectionUri)$(System.TeamProject)/_build/results?buildId=$(Build.BuildId)&view=artifacts&pathAsName=false&type=publishedArtifacts"

    echo "## Veracode SCA Report" > $SUMMARY
    echo "" >> $SUMMARY
    echo "Artifact: **sca-report**" >> $SUMMARY
    echo "" >> $SUMMARY
    echo "[Open SCA HTML Report]($REPORT_URL)" >> $SUMMARY

    echo "##vso[task.uploadsummary]$SUMMARY"
routes:
  - conditions:
      - prefix: /paty
    services:
      - name: portaladministrativo-service
        port: 80
    requestHeadersPolicy:
      set:
        - name: Origin
          value: https://patycert.tuya.com.co
    responseHeadersPolicy:
      set:
        - name: Access-Control-Allow-Origin
          value: "*"
        - name: Access-Control-Allow-Methods
          value: "GET, POST, PUT, DELETE, OPTIONS"
        - name: Access-Control-Allow-Headers
          value: "*"
