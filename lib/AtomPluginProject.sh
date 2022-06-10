import NodejsProject.sh  ;$L1;$L2

DeclareClass AtomPluginProject NodejsProject

function AtomPluginProject::__construct()
{
	:
}

function AtomPluginProject::depsInstall()
{
	(
		echo "${this[name]}:"
		Project::cdToRoot
		apm install | gawk '{print "   "$0}'
	)
}

function AtomPluginProject::depsUpdate()
{
	(
		echo "${this[name]}:"
		Project::cdToRoot
		apm update | gawk '{print "   "$0}'
	)
}
