import Project.sh  ;$L1;$L2
import bg_json.sh  ;$L1;$L2

DeclareClass NodejsProject PackageProject

function NodejsProject::__construct()
{
	[ ! -f "${this[absPath]}/package.json" ] && assertError -v this[absPath] "package.json is missing from this project"

	# read the package.json if it exists
	Object::fromJSON "${this[absPath]}/package.json"
	#read -r this[displayName] this[type] this[version] < <(getProjectNameTypeAndVersion "${this[absPath]}/package.json")
}


function NodejsProject::depsInstall()
{
	(
		echo "${this[name]}:"
		Project::cdToRoot
		npm install | gawk '{print "   "$0}'
	)
}

function NodejsProject::depsUpdate()
{
	(
		echo "${this[name]}:"
		Project::cdToRoot
		npm update | gawk '{print "   "$0}'
	)
}


function NodejsProject::publishCommit()
{
	if [ "${this[releasePending]}" ]; then
		confirm "WARNING: this needs refactoring. be sure to run 'npm install' before publishing"

		git ${this[gitFolderOpt]} tag v"${this[version]}"
		git ${this[gitFolderOpt]} push --tags
		(
			cd "${this[absPath]}" || assertError
			npm publish
		)
	fi
}

function NodejsProject::setVersion()
{
	local newVersion="${1#v}"

	if [ "${this[lastRelease]}" ] && ! versionGt "$newVersion" "${this[lastRelease]}"; then
		assertError -v project:this[name] -v lastRelease:this[lastRelease] -v specifiedVersion:newVersionSpec "The specified version number is not greater than the last published release version number"
	fi

	local version="$newVersion"
	local fullUsername="$(git config user.name)"
	local userEmail="$(git config user.email)"
	local packageName="${this[packageName]}"

	#"version": "2.1.0",
	bgawk -i -q -v newVersion="$newVersion" '
		BEGIN {nestLevel=0; found=0}
		/[{][[:space:]]*$/ {nestLevel++}
		/^[[:space:]]*[}][[:space:]]*,?[[:space:]]*$/ {nestLevel--}

		nestLevel==1 && !found && /^[[:space:]]*["]version["][[:space:]]*:/ {
			found=1
			if (match($0,/(^[[:space:]]*["]version["][[:space:]]*:[[:space:]]*)["](.*)["]([[:space:]]*,?[[:space:]]*)$/, rematch)) {
				$0 = sprintf("%s\"%s\"%s", rematch[1], newVersion, rematch[3])
			} else {
				assert("logic error: regex did not match ");
			}
		}
		END {
			exit (found) ? 0 : 36;
		}
	' "${this[absPath]}/package.json"

	this[version]="$newVersion"
}
