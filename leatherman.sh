#!/bin/bash

####################################################################################
# Leatherman - multitool for rapid node, postgres, git deployments and maintenance #
####################################################################################

if [ -f "leatherman.sh" ]
then
	source ./settings.sh
fi

ME="${0##*/}"

command=$1
subcommand=$2

if [[ "${command}" == "" || "${command}" == "bootstrap" ]]
then
	if [ -f "leatherman.sh" ]
	then
		echo -e "\n\x1B[101m ${PRODUCT}, version ${VERSION} \x1B[49m\n"
	else
		command="bootstrap"
	fi
fi

#get current folder (this is the programatics installation path)
installdir=$(pwd -P)
cd ..
pgmdir=$(pwd -P)/webapp
datadir=$(pwd -P)/data
backupdir=$(pwd -P)/backups

case ${command} in
install | update )
	shortcut=0
	prereqs=0
	webapp=0
	webappnode=0
	data=0
	datanode=0
	cluster=0
	case ${subcommand} in
	all )
		shortcut=1
		prereqs=1
		webapp=1
		data=1
		;;
	shortcut )
		shortcut=1
		;;
	prereqs )
		prereqs=1
		;;
	webapp )
		webapp=1
		;;
	data )
		data=1
		;;
	webappnode )
		echo -e "webappnode not implemented"
		;;
	datanode )
		echo -e "dbappnode not implemented"
		;;
	cluster )
		echo -e "cluster not implemented"
		;;
	*)
		echo -e "Invalid ${command} option '$(tput bold)${subcommand}$(tput sgr0)' valid options are:

all
shortcut
prereqs
webapp
data
webappnode
datanode
cluster
"
		exit 1
		;;
	esac

	if [[ $shortcut == 1 ]]
	then 
		#go to user folder
		cd ~

		#remove any prior functions related to programmatic from bash profile
		sed -i.bak "/#start_${PRODUCT}/,/#end_${PRODUCT}/d" .bash_profile 

		#create new profile, pointing to new programatics installation
		echo "#start_${PRODUCT}
function ${SHORTCUT}
{
cd ${installdir}
./${ME} \"$@\"
} 
#end_${PRODUCT}" >.bash_profile.add
		cat .bash_profile .bash_profile.add > .bash_profile

		#.bash_profile.bak will contain a previous version, just in case anything went wrong
	fi

	if [[ $prereqs == 1 ]]
	then
		which -s brew
		if [[ $? != 0 ]] ; then
			echo Installing brew... 
			CI=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"
		else
			echo brew is installed, updating... 
			brew update
		fi

		which -s psql
		if [[ $? != 0 ]] ; then
			echo Installing postgres... 
			brew install postgres
		else
			echo postgres is installed, updating... 
			brew upgrade postgres
			brew postgresql-upgrade-database
		fi

		echo "Starting postgres services..."
		brew services start postgresql

		which -s node
		if [[ $? != 0 ]] ; then
			echo Installing node... 
			brew install node
			npm install pm2@latest -g
		else
			echo node is installed, upgrading... 
			brew upgrade node
		fi

		until PGPASSWORD=${POSTGRES_PSWD} psql template1 -U ${POSTGRES_USER} -c "select 1" > /dev/null 2>&1 || [ $RETRIES -eq 0 ]; do
		echo "Waiting for postgres server, $((RETRIES--)) remaining attempts..."
		sleep 1
		done
	fi

	if [[ $webapp == 1 ]]
	then
		echo Installing webapp...

		cd "${pgmdir}"
		cd ..
		rm -r "${pgmdir}"
        mkdir "${pgmdir}"
		cd "${pgmdir}"
		git clone ${GITREPO} .
		echo node_modules/ >.gitignore
		npm init -f
		npm install --save 
		npm audit fix
	fi

	if [[ $data == 1 ]]
	then
		if [ "$( PGPASSWORD=${POSTGRES_PSWD} psql template1 -U ${POSTGRES_USER} -tAc "SELECT 1 FROM pg_database WHERE datname='${DBNAME}'" )" = '1' ]
		then
			echo "Database already exists"
			#starting the app will upgrade it via sequelize
		else
			echo "Database does not exist, creating and seeding prerequsites"
			rm -rf "${datadir}"
			mkdir "${backupdir}"
			initdb "${datadir}"
			mkdir "${datadir}/files"
			pg_ctl -D "${datadir}" -l logfile start
			PGPASSWORD=${POSTGRES_PSWD} psql template1 -U ${POSTGRES_USER} -c "CREATE USER ${DBUSER} with password '${DBPSWD}' Login CreateDB"
			PGPASSWORD=${DBPSWD} psql template1 -U ${DBUSER} -c "CREATE DATABASE ${DBNAME}"
		fi
	fi

	exit 0
	;;
uninstall )
	read -p "Uninstall ${PRODUCT}?" -n 1 -r
	echo ""
	if [[ $REPLY =~ ^[Yy]$ ]]
	then
		brew uninstall --force postgres
		brew uninstall --force node
		rm -rf /usr/local/var/postgres
	    CI=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/uninstall.sh)"
		exit 0
	else
		exit 1
	fi
	;;
start )
	case ${subcommand} in
	development|test|production )
		echo -e "Starting ${PRODUCT} in $(tput bold)${subcommand}$(tput sgr0) mode"
		cd ${pgmdir}
		pm2 start ecosystem.config.js --env ${subcommand}
		cd ${installdir}
		;;
	* )
		echo -e "Invalid start option '$(tput bold)${subcommand}$(tput sgr0)' valid options are:

development
test
production
"
		exit 1
		;;
	esac
	exit 0
	;;
stop )
	pm2 stop ${PRODUCT}
	exit 0
	;;
data )
	case ${subcommand} in
		backup )
			bkupfile=$(date "+%Y%m%d-%H%M%S")
			PGPASSWORD=${DBPSWD} pg_dump -U ${DBUSER} ${DBNAME} > ${backupdir}/${bkupfile}.sql
			zip  ${backupdir}/${bkupfile}.zip ${datadir}/files/*
			exit 0
			;;
		restore )
			bkupfile="$3.zip"
			if [[ -f ${bkupfile} ]]
			then
				echo "Restoring data files"
				rm -rf ${datadir}/files
				unzip $3.zip ${datadir}/files
			else
				echo "No files to restore"
				mkdir ${datadir}/files
			fi
			bkupfile="$3.sql"
			if [[ -f ${bkupfile} ]]
			then
				echo "Restoring data base"
				PGPASSWORD=${DBPSWD} psql template1 -U ${DBUSER} -c "DROP DATABASE ${DBNAME}"
				PGPASSWORD=${DBPSWD} psql template1 -U ${DBUSER} -c "CREATE DATABASE ${DBNAME}"
				PGPASSWORD=${DBPSWD} psql ${DBNAME} -U ${DBUSER} < $3.sql
			else
				echo "No data base to restore"
			fi
			exit 0
			;;
	esac
	exit 0
	;;
push )
	case ${subcommand} in
		webapp )
			pwd ${pgmdir}
			git add *
			git commit -a -m ${$@:2}
			git push
			pwd ${installdir}
			exit 0
			;;
		bootstrap )
			git add *
			git commit -a -m ${$@:2}
			git push
			exit 0
			;;
		* )
			echo -e "Invalid push option '$(tput bold)${subcommand}$(tput sgr0)' valid options are:

webapp
installation
"
			;;
	esac
	exit 0
	;;
bootstrap )
	target=$2
	echo "Bootstrapping files to ${target}"
	cd ${target}
	mkdir installation
	cd installation
	git clone https://github.com/qaTestLimited/Leatherman.git .
	pwd
	echo nano next
	nano settings.sh
	echo after nano
	cd ..
	pwd
	installation/leatherman.sh install
	echo node_modules/ >.gitignore
	exit 0
	;;
configure )
	nano ${installdir}/settings.sh
	exit 0
	;;
help|* )
	echo -e "$(tput bold)syntax:$(tput sgr0)
	
programatics <command> <option>
		
$(tput bold)commands and options:$(tput sgr0)

install all|shortcut|prereqs|webapp|data|webappnode|datanode|cluster
update all|shortcut|prereqs|webapp|data|webappnode|datanode|cluster
uninstall
start <development|test|production>
stop
data backup|restore <backupname>
push webapp|bootstrap <comment>
configure
bootstrap
help
"
	exit 0
	;;
esac
