#!/bin/bash

# ==============================================================================
# AUTOMATIZIRANI ASL PIPELINE (DICOM -> REGIONALNA ANALIZA U mL)
# ==============================================================================

# 1. POSTAVKE PUTANJA
BASE_DIR="/home/pc/Data/Test"
DICOM_DIR="$BASE_DIR/DICOM/PA000001/ST000001"
OUTPUT_DIR="$BASE_DIR/NIfTI_output"
ASL_OUT="$OUTPUT_DIR/asl_output"
ATLAS="$FSLDIR/data/atlases/HarvardOxford/HarvardOxford-cort-maxprob-thr25-2mm.nii.gz"
MNI_REF="$FSLDIR/data/standard/MNI152_T1_2mm_brain.nii.gz"

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

echo "--> Korak 1: Konverzija DICOM u NIfTI..."
dcm2niix -z y -p y -o "$OUTPUT_DIR" "$DICOM_DIR"

# Identifikacija datoteka
T1_RAW=$(ls ST000001_SG_3D_T1_*.nii.gz | head -n 1)
PD_RAW=$(ls ST000001_3D_PD_*.nii.gz | head -n 1)
TI1=$(ls ST000001_3D_ASL_TI_=_1800*.nii.gz)
TI2=$(ls ST000001_3D_ASL_TI_=_2200*.nii.gz)
TI3=$(ls ST000001_3D_ASL_TI_=_2600*.nii.gz)

echo "--> Korak 2: Spajanje Multi-TI podataka..."
fslmerge -t ASL_multiTI.nii.gz "$TI1" "$TI2" "$TI3"

echo "--> Korak 3: Reorijentacija i BET..."
fslreorient2std "$T1_RAW" T1_std.nii.gz
fslreorient2std ASL_multiTI.nii.gz ASL_std.nii.gz
fslreorient2std "$PD_RAW" PD_std.nii.gz

bet T1_std.nii.gz T1_brain.nii.gz -f 0.4 -g 0
flirt -in T1_brain.nii.gz -ref T1_brain.nii.gz -applyisoxfm 1.0 -out T1_brain_light.nii.gz

echo "--> Korak 4: Pokretanje OXFORD_ASL (PV Corr uključen)..."
# Korištenje ispravnog TR-a (6.0s umjesto 0.006s)
oxford_asl \
  -i ASL_std.nii.gz \
  -o "$ASL_OUT" \
  -c PD_std.nii.gz \
  --tis 1.8,2.2,2.6 \
  --bolus 1.8 \
  --casl --iaf diff --alpha 0.85 --tr 0.006 --cgain 0.1 \
  --spatial --fixbolus --mc --artoff \
  -s T1_brain_light.nii.gz \
  --pvcorr

echo "--> Korak 5: Registracija na MNI prostor..."
flirt -in T1_brain_light.nii.gz -ref "$MNI_REF" -out T1_to_MNI.nii.gz -omat T1_2_MNI.mat
convert_xfm -omat asl_2_MNI.mat -concat T1_2_MNI.mat "$ASL_OUT/native_space/asl2struct.mat"

# Primjena na PV-korigirane mape (za regionalnu analizu)
flirt -in "$ASL_OUT/native_space/pvcorr/perfusion_calib.nii.gz" -ref "$MNI_REF" -applyxfm -init asl_2_MNI.mat -out CBF_PV_MNI.nii.gz
flirt -in "$ASL_OUT/native_space/pvcorr/arrival.nii.gz" -ref "$MNI_REF" -applyxfm -init asl_2_MNI.mat -out ATT_PV_MNI.nii.gz

echo "--> Korak 6: Generiranje finalne tablice (mL i stupci)..."

# Zaglavlje s točka-zarezom za bolju Excel kompatibilnost
echo "Regija;Volumen_mL;CBF_Mean;ATT_Mean" > Finalna_Tablica.csv

# 6a. Globalne vrijednosti (GM)
G_VOL_MM3=$(fslstats "$ASL_OUT/native_space/mask.nii.gz" -V | awk '{print $2}')
G_VOL_ML=$(echo "scale=2; $G_VOL_MM3 / 1000" | bc)
G_CBF=$(cat "$ASL_OUT/native_space/pvcorr/perfusion_calib_gm_mean.txt")
G_ATT=$(cat "$ASL_OUT/native_space/pvcorr/arrival_gm_mean.txt")
echo "Global Brain;$G_VOL_ML;$G_CBF;$G_ATT" >> Finalna_Tablica.csv

# 6b. White Matter vrijednosti
WM_CBF=$(cat "$ASL_OUT/native_space/pvcorr/perfusion_wm_calib_wm_mean.txt")
WM_ATT=$(cat "$ASL_OUT/native_space/pvcorr/arrival_wm_wm_mean.txt")
echo "White Matter;-;$WM_CBF;$WM_ATT" >> Finalna_Tablica.csv

# 6c. Regionalne vrijednosti (Harvard-Oxford 48 regija)
echo "--> Čitam regionalnu statistiku..."

mapfile -t NAMES < <(grep "<label" $FSLDIR/data/atlases/HarvardOxford-Cortical.xml | sed 's/.*>\(.*\)<.*/\1/')
mapfile -t CBFS < <(fslstats -K "$ATLAS" CBF_PV_MNI.nii.gz -M)
mapfile -t ATTS < <(fslstats -K "$ATLAS" ATT_PV_MNI.nii.gz -M)
mapfile -t VOLS < <(fslstats -K "$ATLAS" "$ATLAS" -V | awk '{print $2}')

# Loop kroz sve detektirane regije
NUM_REGS=${#NAMES[@]}
for ((i=0; i<NUM_REGS; i++)); do
    V_ML=$(echo "scale=2; ${VOLS[$i]} / 1000" | bc)
    echo "${NAMES[$i]};$V_ML;${CBFS[$i]};${ATTS[$i]}" >> Finalna_Tablica.csv
done

echo "=============================================================================="
echo "GOTOVO! Tvoja tablica se nalazi u: $OUTPUT_DIR/Finalna_Tablica.csv"
echo "Možeš je otvoriti u Excelu. Koristi 'explorer.exe .' za brzi pristup."
echo "=============================================================================="