#!/usr/bin/python
import urllib2
import simplejson
import sys

build_number=sys.argv[1]
if len(sys.argv)>2:
  platform=sys.argv[2]
else:
  platform="precise"

print "# grabbing build env for build # %s for platform %s" % (build_number, platform)
url="http://build.monkeypuppetlabs.com:8080/job/gate-nova-matrix/BUILD_TYPE=mini-ha,INSTANCE_IMAGE=jenkins-%s-v2,label=nova/%s/api/json" % (platform, build_number)
json=urllib2.urlopen(url).read()
(true,false,null) = (True,False,None)
profiles = eval(json)

for e in profiles['actions'][0]['parameters']:
  print "%s=%s" % (e['name'], e['value'])

print "# paste the above in your terminal to re-test"
