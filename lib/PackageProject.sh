import Project.sh  ;$L1;$L2

DeclareClass PackageProject Project

# A package project can be built into a deb or rpm package for distribution.
# It requires the project to have a pkgControl/ folder that configures how the package will
# be built.
function PackageProject::__construct()
{
	# pkg projects store the version in the doc/changelog file.
	if [ -f "${this[absPath]}"/doc/changelog ]; then
		this[version]="$(gawk 'NR==1 {print gensub(/^[^(]*[(]|[)].*$/,"","g",$0); exit}' "${this[absPath]}"/doc/changelog )"
		this[version]="${this[version]#v}"
	else
		# typically this default wont kick in because the template for new projects has a ./doc/changelog file with the starting version
		this[version]="0.0.0"
	fi
}

# usage: $obj.installAssets
# the default is to iterate each assetType present in the manifest and look for a helper function or cmd
# named with the assetType name (i.e. function bgAssetInstall_<assetName> or cmd bg-dev-install_<assetName>).
function PackageProject::installAssets()
{
	$this.cdToRoot
	static::PackageAsset::installAssets "$@"
}

function PackageProject::install()
{
	local verbosity=${verbosity} noUpdateFlag
	while [ $# -gt 0 ]; do case $1 in
		-v|--verbose) ((verbosity++)) ;;
		-q|--quiet) ((verbosity--)) ;;
		--no-update) noUpdateFlag=1 ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local -x INSTALLTYPE="$1"
	local -x DESTDIR="$2"

	if [ "$INSTALLTYPE" == "detect" ]; then
		INSTALLTYPE=""
		which apt &>/dev/null && INSTALLTYPE="deb"
		[ ! "$INSTALLTYPE" ] && which rpm &>/dev/null && INSTALLTYPE="rpm"
		[ ! "$INSTALLTYPE" ] && INSTALLTYPE="deb"
	fi
	[ "$DESTDIR" == "/" ] && DESTDIR=""

	if [ ! "$DESTDIR" ]; then
		# TODO: detect if the project is already installed and change "install" to "upgrade"
		[ -f pkgControl/preinst ] && { sudo ./pkgControl/preinst "install" || assertError; }
	fi

	[ "$DESTDIR" ] && [ ! -e "$DESTDIR/" ] && mkdir -p "$DESTDIR"
	local PRECMD; [ ! -w "$DESTDIR" ] && PRECMD="bgsudo "

	local UNINSTSCRIPT="${DESTDIR}/var/lib/bg-core/$pkgName/uninstall.sh"
	local HOSTMANIFEST="${DESTDIR}/var/lib/bg-core/$pkgName/hostmanifest"

	[ ${verbosity:-0} -ge 1 ] && printf "installing to %s\n" "${DESTDIR:-host filesystem}"

	export DESTDIR INSTALLTYPE PRECMD UNINSTSCRIPT pkgName manifestProjPath
	#export -f manifestReadOneType --file="$manifestProjPath" bgOptionsEndLoop varSet printfVars varIsA

	### if there is a previous installation, remove it
	if [ -f "$UNINSTSCRIPT" ]; then
		$this.uninstall "$INSTALLTYPE" "$DESTDIR"
	fi

	### Start the HOSTMANIFEST file
	# fsTouch can not use $PRECMD b/c its a function (sudo only does files) but fsSudo will prompt sudo as needed
	fsTouch -p "$HOSTMANIFEST"
	$PRECMD truncate -s0 "$HOSTMANIFEST"

	### Start the $UNINSTSCRIPT script
	$PRECMD mkdir -p "${DESTDIR}/var/lib/bg-core/$pkgName"
	$PRECMD bash -c 'cat >"'"${UNINSTSCRIPT}"'"  <<-EOS
		#!/usr/bin/env bash
		#(its better to create a bespoke assertError) # [ -f /usr/lib/bg_core.sh ] && source /usr/lib/bg_core.sh
		[ "\$(type -t assertError)" != "function" ] && function assertError() {
		   printf "uninstall script failed: \n\tlocation:\$0(\${BASH_LINENO[0]})\n\tline: \$(gawk 'NR=='"\${BASH_LINENO[0]}"'' \$0)\n"
		   exit 2
		}
		function rmFile() {
		   local recurseFlag; [ "\$1" == "-r" ] && { recurseFlag="-r"; shift; }
		   local dirFlag;     [ -d "\$1" ] && dirFlag="-r"
		   [ "\$dirFlag" ] && [[ "\$1" =~ ^(/[^/]*)$ ]] && { printf "uninstall script warning: refused to remove top level folder '%s'\n" "\$1" ; return; }
		   [ -e "\$1" ]        && { \$preUninstCmd rm \$dirFlag -f "\$1" || return; }
		   [ "\$recurseFlag" ] && { \$preUninstCmd rmdir --ignore-fail-on-non-empty -p  "\${1%/*}" &>/dev/null; true; }
		   true
		}
		preUninstCmd=""; [ ! -w "\$0" ] && preUninstCmd="sudo "; true
		EOS' || assertError "error writing the initial uninstall script file contents"
	$PRECMD chmod a+x "${UNINSTSCRIPT}" || assertError

	### Update the asset manifest
	[ ! "$noUpdateFlag" ] && $this.updateProjectManifest

	$this.installAssets

	static::PackageAsset::_installFilesToDst --flat manifest "/var/lib/bg-core/$pkgName" "manifest" "$manifestProjPath"

	### Finish the $UNINSTSCRIPT script
	$PRECMD bash -c 'cat >>"'"${UNINSTSCRIPT}"'"  <<-EOS
		[ "$DESTDIR" ] && [ -d "$DESTDIR/DEBIAN" ] && { rm -f "$DESTDIR/DEBIAN/"*; rmdir  "$DESTDIR/DEBIAN/"; }
		rmFile -r '${HOSTMANIFEST}'
		rmFile -r '${UNINSTSCRIPT}'
		true
		EOS' || assertError "error writing the final uninstall script file contents"
	$PRECMD chmod a+x "${UNINSTSCRIPT}"

	# if installing to the local host, run the posinstall script
	if [ ! "$DESTDIR" ]; then
		# TODO: detect if the project is already installed and change "install" to "upgrade"
		[ -f pkgControl/postinst ] && { sudo ./pkgControl/postinst "install"; }
	fi
}

# usage: bg-dev static::PackageAsset::uninstall [-v|-q] [--pkgType=deb|rpm]
function static::PackageAsset::uninstall()
{
	local verbosity=${verbosity}
	while [ $# -gt 0 ]; do case $1 in
		-v|--verbose) ((verbosity++)) ;;
		-q|--quiet) ((verbosity--)) ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local -x INSTALLTYPE="$1"
	local -x DESTDIR="$2"

	# TODO: detect needs to detect the type of DESTDIR, not the host
	if [ "$INSTALLTYPE" == "detect" ]; then
		INSTALLTYPE=""
		which apt &>/dev/null && INSTALLTYPE="deb"
		[ ! "$INSTALLTYPE" ] && which rpm &>/dev/null && INSTALLTYPE="rpm"
		[ ! "$INSTALLTYPE" ] && INSTALLTYPE="deb"
	fi
	[ "$DESTDIR" == "/" ] && DESTDIR=""

	# if the DESTDIR does not exist, the unistall is done by definition
	[ ! -e "$DESTDIR/" ] && return 0

	# see if we need sudo to modify DESTDIR
	local PRECMD; [ ! -w "$DESTDIR" ] && PRECMD="bgsudo "

	# if uninstalling from the local host, run the prerm script
	if [ ! "$DESTDIR" ]; then
		[ -f /var/lib/dpkg/info/${pkgName}.prerm ] && { sudo /var/lib/dpkg/info/${pkgName}.prerm "remove"; }
	fi

	local UNINSTSCRIPT="${DESTDIR}/var/lib/bg-core/$pkgName/uninstall.sh"

	# if there is a $UNINSTSCRIPT installed, call it to remove the last version before we install the current version.
	# this makes it clean when we remove or rename files in this library so that we dont leave obsolete files in the system
	[ -x "${UNINSTSCRIPT}" ] && { "${UNINSTSCRIPT}" || assertError -v UNINSTSCRIPT "
		The uninstall script from the previous installation ended with an error.
		You can edit that script to get around the error and try again. If you
		remove or rename that script this step will be skipped by the installer.
		There may or may not be steps in the uninstall script that need to complete
		before this package will install correctly so if you remove it, make a copy"; }

	# if uninstalling from the local host, run the postrm script
	if [ ! "$DESTDIR" ]; then
		[ -f /var/lib/dpkg/info/${pkgName}.postrm ] && { sudo /var/lib/dpkg/info/${pkgName}.postrm "remove"; }
	fi
}


function PackageProject::updateManifest()
{
	import PluginType.PackageAsset ;$L1;$L2

	static::PackageAsset::updateProjectManifest "$@";
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

# usage: $proj.make <pkgType>
function PackageProject::buildPkg()
{
	import PluginType.PackageAsset ;$L1;$L2

	$this.cdToRoot
	local runLintianFlag makeChangesFlag
	while [ $# -gt 0 ]; do case $1 in
		--lintian) runLintianFlag=1 ;;
		--changes) makeChangesFlag=1 ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local pkgType="${1:-deb}"
	local pkgName="${this[packageName]}"

	$this.cdToRoot

	# scan for assets to make sure the list of assets is up-to-date
	$this.updateManifest

	# make sure that the funcman assets are up-to-date. funcman manintains the manifest file if any manpages are added or removed.
	funcman_runBatch -q

	this[version]="$(dpkg-parsechangelog -ldoc/changelog | sed -n -e 's/^Version:[ \t]*//p')"

 	case $pkgType in
		deb|both)
			echo "making deb package..."
			assertFileExists pkgControl/debControl "pkgControl/debControl is required to build a deb package. See 'control' file in debian policy documentation"

			local stagingFolder=".bglocal/pkgStaging-deb"
			rm -rf "$stagingFolder"

			### Install the package's assets into the stagingFolder
			$this.install --no-update "deb" "$stagingFolder"

			### Make the DEBIAN pkg control folder in the stagingFolder from the shared pkgControl folder
			mkdir -p "$stagingFolder/DEBIAN"
			if [ -e pkgControl/lintianOverrides ]; then
				mkdir -p "$stagingFolder/usr/share/lintian/overrides/"
				cp pkgControl/lintianOverrides "$stagingFolder/usr/share/lintian/overrides/${this[packageName]}"
				chmod 0644 "$stagingFolder/usr/share/lintian/overrides/${this[packageName]}"
			fi
			for i in preinst postinst prerm postrm; do
				if [ -f "pkgControl/$i" ]; then
					cp "pkgControl/$i" "$stagingFolder/DEBIAN/"
					chmod 775 "$stagingFolder/DEBIAN/$i"
				fi
			done
			chmod -R g-w "$stagingFolder/"

			local generatedControl=".bglocal/debControl.buildPkg"
			cp pkgControl/debControl "$generatedControl"

			local targetArch="$(gawk -F': *'   '$1=="Architecture" {print $2; exit}'  "$generatedControl")"
			assertNotEmpty targetArch "Architecture field missing from pkgControl/debControl"

			if [ "$targetArch" == "%ARCH%" ]; then
				targetArch="$(dpkg --print-architecture)"
				sed -i "s/%ARCH%/$targetArch/g" "$generatedControl"
			fi

			local debFile="${this[packageName]}_${this[version]}_$targetArch.deb"
			local changesFile="${this[packageName]}_${this[version]}_$targetArch.changes"

			### Create the binary control file for the pkg from the source control file
			dpkg-gencontrol -c"$generatedControl" -ldoc/changelog -fpkgControl/files -P"$stagingFolder/"

			### Make the deb file from the staging folder
			fakeroot dpkg-deb -Zgzip --build "$stagingFolder/" "$debFile"

			## run lintian to check for issues
			if [ "$runLintianFlag" ]; then
				printf "${csiBold}lintian:${csiNorm} %s\n" "$debFile"
				if ! lintian "$debFile"; then
					echo "stopping because package contains lintian issues."
					return 1
				fi
			fi

			### Create the .changes file which will be used to upload the package to repositories
			if [ "$makeChangesFlag" ]; then
				local publishUser="$(gawk '/^Maintainer:/ {gsub("^.*<|>.*$",""); print}' "$generatedControl")"
				dpkg-genchanges -b  -c"$generatedControl" -ldoc/changelog -fpkgControl/files -u. -O"$changesFile.unsigned"
				if gpg -k "<$publishUser>" &>/dev/null; then
					rm -f "$changesFile"
					if gpg --use-agent --clearsign --batch -u "<$publishUser>" -o "$changesFile" -- "$changesFile.unsigned"; then
						printf "${csiBold}gpg :${csiNorm} signed changes file with %s's key\n" "$publishUser"
						rm "$changesFile.unsigned"
					else
						printf "${csiBold}gpg :${csiRed} FAILED to sign changes file with %s's key. changes file is unsigned${csiNorm}\n" "$publishUser"
						mv "$changesFile.unsigned" "$changesFile"
					fi
				else
					echo "The maintainer user specified in the pkgControl/debControl file, '$publishUser' does not have a gpg key to sign the changes file."
					echo "The .changes file will not be signed"
					mv "$changesFile.unsigned" "$changesFile"
				fi
				chmod 644 "$changesFile"
			fi

			# report finish
			echo "built package '$debFile'"
			;;&

		rpm|both)
			echo "making rpm package..."
			assertFileExists pkgControl/rpmControl "pkgControl/rpmControl is required to build a deb package. See 'control' file in debian policy documentation"
			local stagingFolder=".bglocal/rpmbuilding/pkgStaging-rpm"
			mkdir -p ".bglocal/rpmbuilding"

			$this.install --no-update "rpm" "$stagingFolder"
			chmod -R g-w "$stagingFolder/"

			rpmbuild --define "_topdir .bglocal/rpmbuilding/rpmbuild"  --buildroot "${PWD}/$stagingFolder"   -bb pkgControl/rpmControl
			mv .bglocal/rpmbuilding/rpmbuild/RPMS/noarch/*.rpm .
			;;&
	esac
}

function PackageProject::setVersion()
{
	local newVersion="${1#v}"

	if [ "${this[lastRelease]}" ] && ! versionGt "$newVersion" "${this[lastRelease]}"; then
		assertError -v project:this[name] -v lastRelease:this[lastRelease] -v specifiedVersion:newVersionSpec "The specified version number is not greater than the last published release version number"
	fi

	local version="$newVersion"
	local fullUsername="$(git config user.name)"
	local userEmail="$(git config user.email)"
	local packageName="${this[packageName]}"

	# make sure that the doc/ folder exists
	fsTouch -d "${this[absPath]}/doc/"

	import bg_template.sh ;$L1;$L2

	if [ "${this[version]}" == "${this[lastRelease]}" ] || [ ! -s "${this[absPath]}/doc/changelog" ]; then
		# add a new entry
		templateExpand changelogEntry > "${this[absPath]}/doc/changelog.new"
		[ -f "${this[absPath]}/doc/changelog" ] && cat "${this[absPath]}/doc/changelog" >> "${this[absPath]}/doc/changelog.new"
		mv "${this[absPath]}/doc/changelog.new" "${this[absPath]}/doc/changelog"
	else
		# change the version of the last entry in the file b/c that entry has not yet been published
		bgawk -i \
			-v oldVersion="${this[version]#v}" \
			-v newVersion="$newVersion" '

			!found && /^[[:space:]]*$/ {print $0; next}
			!found {
				found=1
				sub("[(]"oldVersion"[)]", "("newVersion")")
			}
		' "${this[absPath]}/doc/changelog"
	fi

	this[version]="$newVersion"
}



function PackageProject::publishCommit()
{
	echo "PackageProject::publishCommit not yet implemented"
}
