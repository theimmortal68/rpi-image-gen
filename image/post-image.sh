#!/bin/bash

set -eu

deploydir=$1

case ${IGconf_image_compression} in
   zstd|none)
      ;;
   *)
      die "Deploy error. Unsupported compression."
      ;;
esac

images=("${IGconf_image_outputdir}/${IGconf_image_name}"*.${IGconf_image_suffix})
sboms=("${IGconf_image_outputdir}/${IGconf_image_name}"*.sbom)

msg "Deploying image and SBOM"

for image in "${images[@]}" ; do
   case ${IGconf_image_compression} in
      zstd)
         zstd -v -f $image --output-dir-flat $deploydir
         ;;
      none)
         install -v -D -m 644 $image $deploydir
         ;;
      *)
         ;;
   esac
done

for sbom in "${sboms[@]}" ; do
   case ${IGconf_image_compression} in
      zstd)
         zstd -v -f $sbom --output-dir-flat $deploydir
         ;;
      none)
         install -v -D -m 644 $sbom $deploydir
         ;;
      *)
         ;;
   esac
done
