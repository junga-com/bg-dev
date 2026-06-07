import Project.sh  ;$L1;$L2

DeclareClass BashBuiltinProject PackageProject


function BashBuiltinProject::__construct()
{
	:
}


# usage: $obj.make <target>
# Params:
#    <target> : clean|"" : clean removes the built files. empty string creates them
function BashBuiltinProject::make()
{
	make "$@"
}

# override the base class updateManifest to ...
#   1) make the binaries beofre searching for them
#   2) create the manifest from only the resulting binaries
# The PackageProject::updateManifest is too broad for builtin projects because it picks up
# test scripts that should not be installed. Maybe we can make a standard that would allow
# this to use that base implementation but for now this class takes full control.
function BashBuiltinProject::updateManifest()
{
	import PluginType.PackageAsset ;$L1;$L2

	$this.cdToRoot

	#make clean || assertError "'make clean' returned an error code"
	$this.make "$@" || assertError "'make' returned an error code"

	# now iterate the bin/*.so files
	local binFiles=($(fsExpandFiles bin/*.so))
	local binFile; for binFile in "${binFiles[@]}"; do
		local name="${binFile%.so}"
		name="${name##*/}"
		printf "%s %s %s %s\n" "${this[packageName]}" "bashBuiltin" "${name}" "${binFile}"
	done | fsPipeToFile .bglocal/manifest

	fsPipeToFile --didChange .bglocal/manifest
	local hasChanged=$?

	if [ ${hasChanged:-0} -eq 0 ] && [ "$bgVinstalledManifest" ]; then
		echo "updating changes into the vinstalled 'host' manifest file"
		static::PackageAsset::updateVInstalledHostmanifest;
	fi
	if [ ${hasChanged:-0} -eq 0 ] && [ "$bgVinstalledPluginManifest" ]; then
		echo "updating the plugin manifest"
		import bg_plugins.sh  ;$L1;$L2
		$Plugin::buildAwkDataTable --pkgName=${this[packageName]} | fsPipeToFile "$bgVinstalledPluginManifest"
	fi
}

# this helper will be used by PackageProject::installAssets when it finds an asset of
# assetType bashBuiltin in the manifest
function bgAssetInstall_bashBuiltin() {
	static::PackageAsset::_installFilesToDst --flat  ""  "/usr/lib/bash"   "$@" ;
}
