#! /bin/bash

#David Shean
#dshean@gmail.com
#7/31/14

#Utility to download and convert dataflash logs from Pixhawk SD Card

#To do:
#Use kml instead of gpx
#Create shp
#Preserve attitude info
#Better checking of input

echo
if [ -z "$1" ]; then
  echo "No output directory supplied"
  echo "Usage is $0 outdir"
  echo
  exit 1
fi

#sd_logdir='/Volumes/NO NAME/APM/LOGS'
sd_logdir='/Volumes/SHEAN_PX4/APM/LOGS'
sd_logdir='/Users/dshean/Documents/UW/Cascades/MtBaker/20141005_uav/PX4_dlog/test'
#Desired output directory
#out_logdir='/tmp'
out_logdir=$1

#Merge all gpx files into one master track?
merge=true

#This is the script used to dump binary log to csv
dump=/Users/dshean/src/sfm/sdlog2_dump.py

if [ ! -d $out_logdir ] ; then
    mkdir -pv $out_logdir
fi

#Note: need to extract initialization time for PX4 - all times in log are relative
ts_fmt='%Y%m%d_%H%M%S'

#gls can sort numerically 
#log_list=$(gls -1v "$sd_logdir"/*.BIN)
log_list=$(gls -1v "$sd_logdir"/*.bin)

for log in $log_list
do
    echo $log
    bn=$(basename $log)
    #Get birth time
    ts=$(stat -f '%SB' -t $ts_fmt $log)
    #Get last modified time
    #ts=$(stat -f '%Sa' -t $ts_fmt $log)
    out_fn=$out_logdir/${ts}_${bn%.*}
    #out_fn=$out_logdir/${bn%.*}
    
    #Transfer binary logfile
    rsync -av $log ${out_fn}.bin

    #Dump entire log to ascii
    if [ ! -e ${out_fn}.log ] ; then 
        echo "Dumping entire log to ascii"
        $dump $log -v > ${out_fn}.log
    fi
    #Dump merged GPS/ATT information
    if [ ! -e ${out_fn}_GPS_ATT.csv ] ; then 
        echo "Dumping GPS/ATT to csv"
        #Want to delete first GPS line - always 0,0
        #Throw out entries with bad PDOP, usually 99.99
        #$dump $log -m GPS -m ATT -t GPS | sed '2d' | awk 'BEGIN {FS=","; OFS=","} {if($5 < 12.0) print}' > ${out_fn}_GPS_ATT.csv
        $dump $log -m GPS -m ATT -t GPS > ${out_fn}_GPS_ATT.csv
    fi

    #GPS log processing

    pdop_fltr=true
    max_pdop=12.0

    #Dump only GPS data
    if [ ! -e ${out_fn}_GPS.csv ] ; then 
        echo "Dumping GPS to csv"
        $dump $log -m GPS > ${out_fn}_GPS.csv
        #Throw out entries with bad PDOP, usually 99.99
        if $pdop_fltr ; then
            echo "Applying PDOP filter (max $max_pdop)"
            head -1 ${out_fn}_GPS.csv > temp
            awk 'BEGIN {FS=","; OFS=","} {if( $5 < '$max_pdop' ) print}' ${out_fn}_GPS.csv >> temp
            mv ${out_fn}_GPS.csv ${out_fn}_GPS_orig.csv
            mv temp ${out_fn}_GPS.csv
            echo "Input GPS records: $(cat ${out_fn}_GPS_orig.csv | wc -l)"
            echo "Output GPS records: $(cat ${out_fn}_GPS.csv | wc -l)"
        fi
    fi
   
    if [ "$(cat ${out_fn}_GPS.csv | wc -l)" -gt "1" ] ; then  
        #Convert GPS altitude from MSL to HAE
        hae_fn=${out_fn}_GPS_hae.csv
        if [ ! -e $hae_fn ] ; then 
            echo "Converting GPS altitude from MSL to HAE"
            gps_msl2hae_csv.py ${out_fn}_GPS.csv 
        fi
        #Convert GPS week/sec to UTC
        utc_fn=${hae_fn%.*}_utc.csv
        if [ ! -e $utc_fn ] ; then 
            echo "Converting GPS week/sec to UTC"
            px4_dflog_gps2utc.py $hae_fn 
        fi
        #Convert to GPX
        gpx_fn=${utc_fn%.*}.gpx
        if [ ! -e $gpx_fn ] ; then 
            echo "Converting csv to gpx"
            gpsbabel -t -i unicsv,utc=0 -f $utc_fn -x track,merge,discard -o GPX -F $gpx_fn
        fi
    else 
        echo "No valid GPS records in input log"
    fi

    #CAM log processing

    #Dump only CAM data
    if [ ! -e ${out_fn}_CAM.csv ] ; then 
        echo "Dumping CAM to csv"
        $dump $log -m CAM > ${out_fn}_CAM.csv
    fi
    #Convert GPS altitude from MSL to HAE
    hae_fn=${out_fn}_CAM_hae.csv
    if [ ! -e $hae_fn ] ; then 
        echo "Converting GPS altitude from MSL to HAE"
        gps_msl2hae_csv.py ${out_fn}_CAM.csv 
    fi
    #Convert GPS week/sec to UTC
    utc_fn=${hae_fn%.*}_utc.csv
    if [ ! -e $utc_fn ] ; then 
        echo "Converting GPS week/sec to UTC"
        px4_dflog_gps2utc.py $hae_fn 
    fi
    #Convert to GPX
    gpx_fn=${utc_fn%.*}.gpx
    if [ ! -e $gpx_fn ] ; then 
        echo "Converting csv to gpx"
        gpsbabel -t -i unicsv,utc=0 -f $utc_fn -x track,merge,discard -o GPX -F $gpx_fn
    fi
    echo
done

#Merge all gpx log files
ltype=GPS_hae_utc
if $merge ; then
    echo "Merging files"
    echo
    cd $out_logdir
    merge_fn=merge_${ltype}

    csv_list=($(ls *${ltype}.csv))
    #concatenate, sort by time, then remove extraneous headers
    cat ${csv_list[@]} | sort -n | sed "1,$((${#csv_list[@]} - 1))d" > ${merge_fn}.csv

    #Create a shp for viewing
    csv2vrt.py ${merge_fn}.csv 
    ogr2ogr -overwrite -nln $merge_fn ${merge_fn}.shp ${merge_fn}.vrt

    #Should be more careful with this
    gpx_list=($(ls *${ltype}.gpx))
    str=''
    for i in ${gpx_list[@]}
    do
       str+="-f $i " 
    done
    #merge sort by time, discard missing timestamps
    gpsbabel -t -i gpx $str -x track,merge,discard -o gpx -F ${merge_fn}.gpx
fi

exit

