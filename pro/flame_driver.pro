
  ;****************************************************
  ;                 INPUT
  ;****************************************************

  fuel = flame_create_fuel()

  ; text file containing the list of science FITS files that need to be reduced
  fuel.science_filelist = 'input/science.txt'

  ; text file containing the list of FITS files with dark frames (used for bad pixel mask)
  ; if 'none', the default bad pixel mask will be used
  fuel.darks_filelist = 'input/darks.txt'

  ; text file containing the list of FITS files with flat field
  fuel.flats_filelist = 'none'
  
  ; name of the directory where intermediate data products will be saved
  fuel.intermediate_dir = 'intermediate/'

  ; name of the directory where the final output files will be saved
  fuel.output_dir = 'output/'

  ; if 0, then reduce all slits. If n, then reduce slit number n (starting from 1).
  fuel.reduce_only_oneslit = 0

  ; array with y-pixel positions for the traces of the reference star. [0,0] if there is no reference star
  fuel.startrace_y_pos = [547, 560]

  ; if you want to change the range in x-coordinates used to extract the star traces:
  ;fuel.xrange_star = [100, 500]

  ; if we don't have a star on the slit then we have to specify the dithering
  ;fuel.dither_filelist = 'input/dither.txt'

  ; for longslit
  ;fuel.longslit = 1
  ;fuel.longslit_edge = [960, 1090]

  ; specify the output wavelength grid
  ;fuel.OUTPUT_LAMBDA_0 = 1.12
  ;fuel.OUTPUT_LAMBDA_DELTA = 7.5d-5
  ;fuel.OUTPUT_LAMBDA_NPIX = 450
  
  ; create the fuel structure
  flame_initialize_luci, fuel=fuel

;  help, fuel


  ;****************************************************
  ;                 MONITOR STAR
  ;****************************************************
  ; using the star on the reference slit, get seeing, flux, vertical shift,
  ; and dither position for each frame. Also outputs a ps file with the plots.
  
  
  flame_diagnostics, fuel=fuel
  

  ;****************************************************
  ;                 QUICK LOOK
  ;****************************************************
  ; in order to have a quick look at the data, create the simple A-B stack
  

  flame_simple_stack, fuel=fuel


  ;****************************************************
  ;                 DATA CORRECTION
  ;****************************************************
  ; this step corrects the science frames for linearization and bad pixels and 
  ; converts from ADU to electrons
  ; if needed, it also makes a bad pixel mask, otherwise it uses the default one
  ; it will output corrected science frames in the intermediate directory
  

  flame_correct, fuel=fuel

  
  ;****************************************************
  ;               IDENTIFY AND CUTOUT SLITS
  ;****************************************************
  

  flame_getslits, fuel=fuel

  
  ;****************************************************
  ;                 WAVELENGTH CALIBRATION
  ;****************************************************
  

  flame_wavelength_calibration, fuel=fuel


  ;****************************************************
  ;                 SKY SUBTRACTION
  ;****************************************************


  flame_sky_subtraction, fuel=fuel
  

  ;****************************************************
  ;                 RECTIFICATION
  ;****************************************************
  

  flame_rectify, fuel=fuel

  
  ;****************************************************
  ;                 COMBINE FRAMES
  ;****************************************************
  
  
  flame_combine_frames, fuel=fuel
  

  ;****************************************************
  ;                 END: save fuel structure
  ;****************************************************
  

  save, fuel, filename='fuel.sav'

  
;END