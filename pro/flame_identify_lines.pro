;
; For each slit & frame, extract the spectrum of one pixel row, starting
; at the center and assuming the rough calibration. Identify and fit
; the sky emission lines for each row.
;





;*******************************************************************************
;*******************************************************************************
;*******************************************************************************


PRO flame_wavecal_writeds9, OHlines, filename=filename
;
; write a ds9 region file with all the OH line detections
;

  ; extract the wavelength of all identifications
  line_lambdas = OHlines.lambda
  uniq_lambdas = line_lambdas[UNIQ(line_lambdas, SORT(line_lambdas))]

  ; open file
  openw, lun, filename, /get_lun

  ; write header
  printf, lun, '# Region file format: DS9 version 4.1'
  printf, lun, 'global color=red dashlist=8 3 width=3 font="helvetica 10 normal roman" select=1 highlite=1 dash=0 fixed=0 edit=0 move=0 delete=1 include=1 source=1'
  printf, lun, 'image'

  for i_line=0, n_elements(uniq_lambdas)-1 do begin

  	; the wavelength of this OH line
  	this_lambda = uniq_lambdas[i_line]

  	; select the x and y coordinates for this line
  	w_thisline = where(OHlines.lambda eq this_lambda)
  	this_x = OHlines[w_thisline].x
 		this_y = OHlines[w_thisline].y

 	; sort points by y coordinate
 	wsort = sort(this_y)
 	this_x = this_x[wsort]
 	this_y = this_y[wsort]

    ; concatenate points
    all_x = [ this_x, reverse(this_x) ]
    all_y = [ this_y, reverse(this_y) ]

		; in ds9, the first pixel is (1,1), not (0,0)
		all_x += 1
		all_y += 1

    ; make the string with all the points
    all_points = ''
    for i=0,n_elements(all_x)-2 do all_points += strtrim(all_x[i],2) + ',' + cgnumber_formatter(all_y[i], decimals=1) + ','
    ; add the last two points without the final comma
    all_points += strtrim(all_x[-1],2) + ',' + cgnumber_formatter(all_y[-1], decimals=1)

    ; write the line corresponding to this slit
    printf, lun, 'polygon(' + all_points + ') # text={' + cgnumber_formatter(this_lambda, decimals=5) + '}'

  endfor

  ; close file
  free_lun, lun


END



;*******************************************************************************
;*******************************************************************************
;*******************************************************************************



PRO flame_wavecal_fitskylines, x=x, y=y, $
	approx_wavecal=approx_wavecal, linewidth=linewidth, $
	line_list=line_list_in, $
	OHlines=OHlines, wavecal=wavecal, plot_title=plot_title

	;
	; Given a 1D sky spectrum, it finds an accurate wavelength solution
	; by fitting the sky emission lines and comparing them to a line list. It outputs
	; the wavelength axis and the Gaussian parameters of each sky line.
	; It needs an approximate wavelength solution and linewidth to identify the sky emission lines.
	;
	;
	; x: (input) array with the pixel x-coordinate
	; y: (input) array with the observed sky in one pixel row
	; approx_wavecal: (input) array with the approximate wavelength for each x
	; linewidth: (input and output) approximate sigma of unresolved sky lines, which will be updated. NB:in pixels
	; line_list: (input) array of expected wavelengths of usable OH lines
	; OHlines: (output) array of structures with parameters for each OH line
	; wavecal: (output) array with the accurate wavelength solution
	; plot_title : (input) string to print as title of the plot
	;


  ; settings:
	; the degree of the polynomial used to describe the wavelength solution
	poly_degree = 5

	; minimum number of OH lines for a reliable wavelength solution
	Nmin_lines = 6

	; convert linewidth to micron (assuming linear wavelength solution)
	linewidth_um = linewidth * (approx_wavecal[3]-approx_wavecal[2])

	; identify the OH lines that are in this wavelength range
	w_lines = where(line_list_in GT min(approx_wavecal, /nan) $
		AND line_list_in LT max(approx_wavecal, /nan), /null )

	; make sure there are OH lines here
	if w_lines EQ !NULL then message, 'Wavelength range does not contain OH lines?!'

	; keep only the OH lines of interest
	line_list = line_list_in[w_lines]

	; make the array that will contain the result of the fitting
	OHlines = []

	; fit a Gaussian to every sky line
	for i_line=0,n_elements(line_list)-1 do begin

		; select the region to fit
		w_fit = where( abs(approx_wavecal-line_list[i_line]) LT 6.0*linewidth_um, /null )

		; check that the region is within the observed range
		if w_fit eq !NULL then continue

    ; check that there actually is signal and it's not just a bunch of NaNs
    if n_elements( where( finite(y[w_fit]), /null ) ) LE 5 then continue

		; error handling for the gaussian fitting
		catch, error_gaussfit
		if error_gaussfit ne 0 then begin
			print, 'GAUSSFIT ERROR STATUS: ' + strtrim(error_gaussfit,2)
			catch, /cancel
			continue
		endif

		; estimate parameters of the Gaussian
		est_peak = max( median( y[w_fit], 3) , /nan)
		est_center = w_fit[ n_elements(w_fit)/2 ]
		est_sigma = linewidth
		est_cont = min( median( y[w_fit], 3) , /nan)

		; Gaussian fit
		!NULL = gaussfit( x[w_fit], y[w_fit], gauss_param, nterms=4, $
			estimates=[est_peak, est_center, est_sigma, est_cont], sigma=gauss_err, chisq=chisq )

		; check that chi square makes sense
		if ~finite(chisq) then continue

		; check that the peak of the Gaussian is positive
		if gauss_param[0] LT 0.0 then continue

		; check that the SNR is high
		if gauss_param[0] LT 5.0*gauss_err[0] then continue

		; check that the center of the Guassian is in the observed range
		if gauss_param[1] LT min(x[w_fit]) or gauss_param[1] GT max(x[w_fit]) then continue

		; check that the Gaussian width makes sense
		if gauss_param[2] LT linewidth/10.0 or gauss_param[2] GT linewidth*10.0 then continue

		; make OHline structure
		this_OHline = { lambda: line_list[i_line], $
			x: gauss_param[1], $
			y: -1.0, $
			sigma: gauss_param[2], $
			peak: gauss_param[0], $
			chisq: chisq }

		; add to the stack
		OHlines = [OHlines, this_OHline]

	endfor

	; if too few lines were found, then no reliable wavelength solution exists
	if n_elements(OHlines) LT Nmin_lines then begin
		OHlines = !NULL
		return
	endif

	; fit a polynomial to the skyline positions
	wavesol_coeff = poly_fit( OHlines.x, OHlines.lambda, poly_degree )

	; calculate polynomial solution
	poly_wl = poly(x, wavesol_coeff)

	; properly handle regions with no information
	; if where( ~finite(y), /null ) NE !NULL then begin	; check if there are NaNs in the input sky spectrum
	; 	nosky_regions = label_region( ~finite(y) )		; this will have zero everywhere and N in the Nth "region" of NaNs
	; 	nosky_regions[0] = nosky_regions[1]			; boundary issue
	; 	nosky_regions[-1] = nosky_regions[-2]		; boundary issue
	; 	if nosky_regions[1] ne 0 then poly_wl[ where(nosky_regions eq nosky_regions[1]) ] = !values.d_NaN	; void the region at the beginning
	; 	if nosky_regions[-2] ne 0 then poly_wl[ where(nosky_regions eq nosky_regions[-2]) ] = !values.d_NaN	; void the region at the end
	; endif

	; charsize
	ch = 0.8

	; panel 1: plot the spectrum
	erase
	cgplot, x, y, charsize=ch, xsty=1, xtit='', ytit='sky flux', title=plot_title, $
		position = [0.15, 0.70, 0.95, 0.96], xtickformat="(A1)", xra=[x[0], x[-1]], /nodata

	; show the OH lines that were identified
	for i_line=0, n_elements(OHlines)-1 do cgplot, OHlines[i_line].x + [0,0], [-2,2]*max(abs(y)), /overplot, color='red'

	; show the spectrum on top, for clarity
	cgplot, x, y, /overplot

	; panel 2: show the wavelength solution
	cgplot, OHlines.x, OHlines.lambda, /ynozero, xra=[x[0], x[-1]], xsty=1, psym=16, color='red', symsize=0.7, $
		xtit='', ytit='expected wavelength', charsize=ch, $
		/noerase, position = [0.15, 0.50, 0.95, 0.70], xtickformat="(A1)"

	; show the polynomial fit
	cgplot, x, poly_wl, color='blue', /overplot

	; panel 3: show the residuals
	cgplot, OHlines.x, 1d4 * (OHlines.lambda-poly(OHlines.x, wavesol_coeff)), /ynozero, xra=[x[0], x[-1]], xsty=1, psym=16, color='red', symsize=0.7, $
		ytit='residuals (angstrom)', charsize=ch, $
		/noerase, position = [0.15, 0.30, 0.95, 0.50], xtickformat="(A1)"
	cgplot, [x[0], x[-1]], [0,0], /overplot, thick=3, linestyle=2

	; panel 4: plot the line widths
	cgplot, OHlines.x, OHlines.sigma, /ynozero, xra=[x[0], x[-1]], xsty=1, psym=16, color='red', symsize=0.7, $
		xtit='pixel coordinate', ytit='line width (pixel)', charsize=ch, $
		/noerase, position = [0.15, 0.10, 0.95, 0.30]

	; show median value of line width
	cgplot, [-1, 2*max(OHlines.x)], [0,0]+median(OHlines.sigma), /overplot, thick=3, linestyle=2

	; update value of linewidth
	linewidth = median(OHlines.sigma)

	; output wavelength solution
	wavecal = poly_wl

END

;*******************************************************************************
;*******************************************************************************
;*******************************************************************************


PRO flame_wavecal_find_OHlines, fuel=fuel, slit_filename=slit_filename, $
	 approx_lambda_axis=approx_lambda_axis, $
	 OHlines=OHlines, wavelength_solution=wavelength_solution

	print, ' '
	print, 'Wavelength solution for ', slit_filename
	print, '*************************************************************************************************'
	print, ' '

	cgPS_open, flame_util_replace_string(slit_filename, '.fits', '_wavecal.ps'), /nomatch


	; load the slit image
	;-----------------------------------------------------------------------------------------------------------

	; read in slit
	im = readfits(slit_filename, hdr)

	; how many pixels on the spatial direction
	N_spatial_pix = (size(im))[2]

	; how many pixels on the wavelength direction
	N_lambda_pix = (size(im))[1]

	; create the x-axis in pixel coordinates
	pix_axis = dindgen( N_lambda_pix )

	; fit all the pixel rows
	;--------------------------------------------------------------------------------------------------------------

	; create the 2D array that will contain the wavelength value for each pixel
	wavelength_solution = im
	wavelength_solution[*] = 0.

	; load line list
	readcol, fuel.util.linelist_filename, line_list, format='D', /silent

	; approximate sky line width (assuming one arcsec slit width)
	approximate_linewidth_um = median(approx_lambda_axis) / (2.36 * fuel.instrument.resolution_slit1arcsec)
	linewidth = approximate_linewidth_um / ( approx_lambda_axis[3] - approx_lambda_axis[2] )

	; start from the central row and go up until the top row, then start from center and go down
	row_number = indgen(N_spatial_pix)
	sorted_rows = [ row_number[N_spatial_pix/2: N_spatial_pix-1] , reverse(row_number[0:N_spatial_pix/2-1]) ]

	; identify first row of bottom half
	i0_bottom = row_number[N_spatial_pix/2-1]

	; as initial guess for the wavelength axis, use what found during the rough wavecal
	wavelength_axis_guess = approx_lambda_axis

	; create the empty array of OHlines structures
	OHlines = []

	print, 'Fitting individual sky lines for every pixel row...'

	; loop through all the pixel rows
	for counter=0, N_spatial_pix-1 do begin

		; index of the row we are considering now
		i_row = sorted_rows[counter]

		; print info on the row
		print, 'row ' + strtrim(i_row, 2) + ' ', format='(a,$)'

		; extract this pixel row from the slit
		this_row = im[*, i_row]

		; if this is the first row of the bottom half, then use the initial wavelength guess
		if i_row eq i0_bottom then wavelength_axis_guess = approx_lambda_axis

		; fit the emission lines and find the wavelength solution
		flame_wavecal_fitskylines, x=pix_axis, y=this_row, $
			approx_wavecal=wavelength_axis_guess, linewidth=linewidth, $
			line_list=line_list, $
			OHlines=OHlines_thisrow, wavecal=wavelength_axis_for_this_row, plot_title='row '+strtrim(i_row,2)

		; if sky lines were not found, then skip to next row
		if n_elements(OHlines_thisrow) EQ 0 then continue

		; set the y coordinate for the OH lines
		OHlines_thisrow.y = i_row

		; save the OH lines from this row
		OHlines = [ OHlines, OHlines_thisrow ]

		; save the wavelength solution
		wavelength_solution[*, i_row] = wavelength_axis_for_this_row

		; if a solution was found, then use it as the initial guess for the next row
		if where(finite(wavelength_axis_for_this_row), /null) NE !NULL then $
			wavelength_axis_guess = wavelength_axis_for_this_row

	endfor

	print, ''

	cgPS_close

END




;*******************************************************************************
;*******************************************************************************
;*******************************************************************************



PRO flame_identify_lines, fuel=fuel

	start_time = systime(/seconds)

  print, ' '
  print, 'flame_wavecal_accurate'
  print, '**********************'
  print, ' '

  ; avoid printing too much stuff (especially from GAUSSFIT)
  quiet_state = !QUIET
  !QUIET = 1

	; loop through all slits
	for i_slit=0, n_elements(fuel.slits)-1 do begin

	  print, 'Finding emission lines for calibration for slit ', strtrim(fuel.slits[i_slit].number,2), ' - ', fuel.slits[i_slit].name
		print, ' '

		; the initial guess for the first frame is from the rough wavelength calibration
		guess_lambda_axis = *(fuel.slits[i_slit]).rough_wavecal

		for i_frame=0, n_elements(*fuel.slits[i_slit].filenames)-1 do begin


				; filename of the cutout
				slit_filename = (*fuel.slits[i_slit].filenames)[i_frame]

				; this slit
				this_slit = fuel.slits[i_slit]

				; identify and measure the OH lines
				flame_wavecal_find_OHlines, fuel=fuel, slit_filename=slit_filename, $
					approx_lambda_axis=guess_lambda_axis, $
					OHlines=OHlines, wavelength_solution=wavelength_solution

				; write a ds9 region file with the identified OH lines
				flame_wavecal_writeds9, OHlines, filename=flame_util_replace_string(slit_filename, '.fits', '_OHlines.reg')

				; ; write a FITS file with the pixel-by-pixel wavelength solution
				; writefits, flame_util_replace_string(slit_filename, '.fits', '_wavecal.fits'), $
				; 	wavelength_solution, headfits(slit_filename)

				; use the median wavecal of the central five pixel rows as guess for the next frame
				central_row = (size(wavelength_solution))[2]/2
				guess_lambda_axis = median( wavelength_solution[ * , central_row-2:central_row+2 ], dimension=2 )

		endfor

	endfor

	; revert to original !QUIET state
	!QUIET = quiet_state
	print, 'It took ', systime(/seconds) - start_time, ' seconds'

END
