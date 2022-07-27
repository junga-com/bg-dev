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


function AtomPluginProject::publishCommit()
{
	if [ "${this[releasePending]}" ]; then
		git ${this[gitFolderOpt]} tag v"${this[version]#v}"
		git ${this[gitFolderOpt]} push --tags
		(
			cd "${this[absPath]}" || assertError
			apm publish --tag v"${this[version]#v}"
		)
	fi
}
