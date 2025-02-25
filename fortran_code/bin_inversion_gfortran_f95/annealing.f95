module annealing


   use constants, only : pi, max_stations, dpi, twopi, max_subf, max_seg, wave_pts2, &
            &   max_subfaults2, wave_pts, max_subfaults
   use retrieve_gf, only : green_dip, green_stk
   use wavelets, only : wavelet_syn
   use wavelet_param, only : max_freq, lnpt 
   use rise_time, only : source
   use get_stations_data, only : dt_channel, used_data
   use random_gen, only : ran1, cauchy
   use misfit_eval, only : misfit_channel
   use modelling_inputs, only : smooth_moment, smooth_slip, smooth_time, io_re, moment_input, emin0, &
            &   t_latest
   use model_parameters, only : segments, ta0, dta, msou, dxs, dys, nxs0, nys0, nx_p, ny_p, v_min, v_max, &
            &   tbl, tbr, v_ref, nxs_sub, nys_sub, time_max, time_min, shear, &
            &   slip0, rake0, rupt_time0, t_rise0, t_fall0, c_depth, beg, dp, np, dip, &
            &   strike, delay_seg, time_ref
   use regularization, only : slip_laplace, time_laplace, define_slip_field, modify_slip_field
   use static_data, only : static_synthetic, static_remove_subfault, &
                       &   static_modify_subfault, static_add_subfault
   use insar_data, only : insar_synthetic, insar_remove_subfault, &
                       &   insar_modify_subfault, insar_add_subfault, &
                       &   insar_remove_ramp, insar_modify_ramp, &
                       &   insar_add_ramp, ramp_length
   use omp_lib
   implicit none
   real :: coef_moment, coef_slip, coef_gps, coef_insar, coef_time
   real :: current_value, min_value, min_dt, area
   real :: insar_misfit0
   integer :: channels, subfaults_segment(max_seg), subfaults
   integer, parameter :: double = kind(1.d0)
   integer, private :: threads
   integer, parameter, private :: max_move=50, accept_max=5


contains


   subroutine n_threads(auto)
   implicit none
   logical :: auto
   threads = 4
   if (auto) threads = 3
   call omp_set_num_threads(threads)
   end subroutine n_threads
   
   
   subroutine initial_model(slip, rake, rupt_time, t_rise, t_fall)
   implicit none
   real :: slip(:, :), rake(:, :), rupt_time(:, :), t_rise(:, :), t_fall(:, :)
   real :: x(max_subfaults2)
   integer :: nxy, i, segment, k, npa, etc
   npa = 0
   do segment = 1, segments
      npa = npa + 4*nxs_sub(segment)*nys_sub(segment)
   end do
   do k = 1, npa
      x(k) = beg(k)+int(ran1()*np(k)-1.0)*dp(k)
   end do
   if (io_re .eq. 0) then
      k = 0
      do segment = 1, segments
         nxy = nxs_sub(segment)*nys_sub(segment)
         subfaults_segment(segment) = nxy
         do i = 1, nxy
            k = k + 1
            slip(i, segment) = x(k)
            k = k + 1
            rake(i, segment) = x(k)
            k = k + 2
            t_rise(i, segment) = (ta0+int(ran1()*msou)*dta)
            t_fall(i, segment) = (ta0+int(ran1()*msou)*dta)
            rupt_time(i, segment) = ran1()* &
     &  (time_max(i, segment)-time_min(i, segment))+time_min(i, segment)
         end do
      end do 
   else
      slip(:, :) = slip0(:, :)
      rake(:, :) = rake0(:, :)
      rupt_time(:, :) = rupt_time0(:, :)
      t_rise(:, :) = t_rise0(:, :)
      t_fall(:, :) = t_fall0(:, :)
   end if
   end subroutine initial_model


   subroutine print_summary(slip, rake, rupt_time, t_rise, t_fall, static, insar, &
      &   get_coeff, ramp)
   implicit none
   real*8, optional :: ramp(18)
   real :: slip(:, :), rake(:, :), rupt_time(:, :)
   real :: t_rise(:, :), t_fall(:, :)
   real amp, moment, moment_reg, dt, value1, er0, slip_reg, gps_misfit, insar_misfit, &
      & time_reg, forward_real(wave_pts2, max_stations), a, b, &
      & forward_imag(wave_pts2, max_stations), cr(wave_pts2), cz(wave_pts2), forward2(wave_pts2)
   real :: rake2, delta_freq, delta_freq0, moment0, kahan_y, kahan_t, kahan_c
   real*8 :: omega, misfit2, ex
   integer :: i, segment, channel, isl, isr, ixs, iys, jf, k, subfault, subfault_seg 
   complex*16 :: z0, forward(wave_pts), z, z1
   logical :: static, get_coeff, insar

   z0 = cmplx(0.d0, 0.d0, double)
   min_dt = 10
   channels = 0
   gps_misfit = 0.0
   insar_misfit = 0.0
   do i = 1, max_stations
      if (dt_channel(i) .gt. 1.e-4) min_dt = min(min_dt, dt_channel(i))
      if (dt_channel(i) .gt. 1.e-4) channels = channels + 1
   end do
   jf = 2**(lnpt-1)+1
!
! Compute synthetics given current fault model
!
   area = dxs*dys*(1.e+10)
   delta_freq0 = 1.0/(2.0**lnpt)
   misfit2 = 0.d0
   do channel = 1, channels
      delta_freq = delta_freq0/dt_channel(channel)
      dt = dt_channel(channel)
      do i = 1, wave_pts
         forward(i) = z0
      end do
      subfault = 0
      do segment = 1, segments
         do iys = 1, nys_sub(segment)
            do ixs = 1, nxs_sub(segment)
               subfault = subfault+1
               subfault_seg = (iys-1)*nxs_sub(segment)+ixs
               rake2 = rake(subfault_seg, segment)*dpi
               a = sin(rake2)*slip(subfault_seg, segment)
               b = cos(rake2)*slip(subfault_seg, segment)
               isl = int((t_rise(subfault_seg, segment)-ta0)/dta+0.5)+1
               isr = int((t_fall(subfault_seg, segment)-ta0)/dta+0.5)+1
               omega = -twopi*delta_freq*rupt_time(subfault_seg, segment)
               z1 = cmplx(cos(omega), sin(omega), double)
               z = cmplx(1.d0, 0.d0, double)
               do i = 1, max_freq
                  forward(i) = forward(i) &
               &  +(a*green_dip(i, channel, subfault)+b*green_stk(i, channel, subfault)) &
               &  *source(i, channel, isl, isr)*z
                  z = z*z1
               end do
            end do
         end do
      end do

      do i = 1, wave_pts
         forward_real(i, channel) = real(forward(i))
         forward_imag(i, channel) = aimag(forward(i))
         cr(i) = forward_real(i, channel)
         cz(i) = forward_imag(i, channel)
      end do
      call wavelet_syn(cr, cz, forward2)
      call misfit_channel(channel, forward2, ex)
      misfit2 = misfit2 + ex
   end do

   amp = 1.0
   moment0 = 0.0
   kahan_y = 0.0
   kahan_t = 0.0
   kahan_c = 0.0
   do segment = 1, segments
      do k = 1, subfaults_segment(segment)
         kahan_y = slip(k, segment)*shear(k, segment)-kahan_c 
         kahan_t = moment0+kahan_y
         kahan_c = (kahan_t-moment0)-kahan_y
         moment0 = kahan_t
!         moment0 = moment0+slip(k, segment)*shear(k, segment)    ! we may need to increase numerical precision
      end do
   end do

   current_value = emin0
   moment = moment0*area
   moment_reg = (moment/moment_input)-1
   if(moment_reg.ge. 0.10)then
      moment_reg = sqrt(5*moment_reg+0.5)
   elseif((-0.1 .lt. moment_reg) .and. (moment_reg .lt. 0.1))then
      moment_reg = (10*moment_reg)**4
   else
      moment_reg = sqrt(-5*moment_reg+0.5)
   endif
!   moment_reg = (moment/moment_input)
   call define_slip_field(slip, rake)
   call slip_laplace(slip_reg)
   call time_laplace(rupt_time, time_reg)
   if (time_reg .lt. 1.0e-9) time_reg = 1.0
 
   coef_gps = 0.0
   coef_insar = 0.0
   insar_misfit0 = 0.0
   if (static) call static_synthetic(slip, rake, subfaults_segment, gps_misfit)
   if (insar) then
      if (present(ramp)) then
         call insar_synthetic(slip, rake, subfaults_segment, insar_misfit, ramp)
      else
         call insar_synthetic(slip, rake, subfaults_segment, insar_misfit)
      endif
      insar_misfit0 = insar_misfit
   endif

   if (get_coeff) then
      coef_moment=smooth_moment*(misfit2 - current_value)
      coef_moment = min(coef_moment, 1.0)
      coef_slip = smooth_slip*misfit2/(slip_reg*amp)
      coef_slip = min(0.003, coef_slip)
      coef_time = smooth_time*misfit2/(time_reg*amp)
      if (static) then
         coef_gps = misfit2/(gps_misfit*amp)
      endif
      if (insar) then
         coef_insar = misfit2/(insar_misfit*amp)
      endif
   endif

   value1 = misfit2+coef_moment*moment_reg+coef_slip*slip_reg*amp
   value1 = value1+coef_time*time_reg
   value1 = value1+coef_gps*gps_misfit+coef_insar*insar_misfit
   subfaults = 0
   do segment = 1, segments
      subfaults_segment(segment) = nys_sub(segment)*nxs_sub(segment)
      subfaults = subfaults+subfaults_segment(segment)
   end do
   write(*,'()')
   write(*,*)'averaged misfit error', misfit2
   write(*,*)'moment error', moment_reg
   write(*,*)'slip smoothness penalization', slip_reg
   write(*,*)'time smoothness penalization', time_reg
   if (static) write(*,*)'static data penalization', gps_misfit
   if (insar) write(*,*)'insar data penalization', insar_misfit
   write(*,*)'total moment of the inversion', moment
   write(*,'(/A, F10.7)')'moment error coefficient', coef_moment
   write(*,*)'slip smoothness penalization coefficient', coef_slip
   write(*,*)'time smoothness penalization coefficient', coef_time
   if (static) write(*,*)'static data penalization coefficient', coef_gps
   if (insar) write(*,*)'insar data penalization coefficient', coef_insar
   write(*,'(/A, I4)')'Amount of variables: ', 5 * subfaults
   write(*,*)'Amount of data values: ', used_data
   current_value = value1
   min_value = value1
   open(12,file='modelling_summary.txt')
   write(12,'(/A/)')'Modelling Report'
   write(12,*)'averaged misfit error', misfit2
   write(12,*)'moment error', moment_reg
   write(12,*)'slip smoothness penalization', slip_reg
   write(12,*)'time smoothness penalization', time_reg
   if (static) write(12,*)'static data penalization', gps_misfit
   if (insar) write(12,*)'insar data penalization', insar_misfit
   write(12,*)'objective function value', value1
   write(12,*)'total moment of the inversion', moment
   write(12,'(/A, F10.7)')'moment error coefficient', coef_moment
   write(12,*)'slip smoothness penalization coefficient', coef_slip
   write(12,*)'time smoothness penalization coefficient', coef_time
   if (static) write(12,*)'static data penalization coefficient', coef_gps
   if (insar) write(12,*)'insar data penalization coefficient', coef_insar
   write(12,'(/A, I4)')'Amount of variables: ', 5 * subfaults
   write(12,*)'Amount of data values: ', used_data
   close(12)
   end subroutine print_summary
   

   subroutine annealing_iter3(slip, rake, rupt_time, t_rise, t_fall, t)
   implicit none
   integer isl, isr, n_subfault(max_subfaults), n_accept, &
   & nbb, i, k, npb, nn, nran, subfault_seg, segment, channel, subfault, iys, &
   & ixs, n_total, j
   real slip(:, :), rake(:, :), rupt_time(:, :), &
   & t_fall(:, :), t_rise(:, :), t, &
   & duse, ause, vuse, forward_real(wave_pts, max_stations), forward_imag(wave_pts, max_stations), &
   & de, rand, c, aux, dpb, amp, moment_reg, value1, gps_misfit, &
   & moment, d_sub, a_sub, slip_reg, a, b, moment0, &
   & time_reg, t_save, a_save, d_save, x, kahan_y, kahan_t, kahan_c, &
   & l_save, r_save, cr(wave_pts2), cz(wave_pts2), forward2(wave_pts2), &
   & slip_beg, slip_max, slip_end, angle_beg, angle_end, angle_max, &
   & rupt_beg, rupt_end, rupt_max, rise_time_beg, rise_time_end, rise_time_max
   real*8 :: forward_real2(wave_pts, max_stations), forward_imag2(wave_pts, max_stations)
   real :: delta_freq0, delta_freq, rake2!, ex!, misfit2
   real*8 :: omega, misfit2, ex
   complex :: green_subf
   complex*16 :: z, z1, forward(wave_pts), z0

   z0 = cmplx(0.d0, 0.d0, double)
   value1 = 0.0
   gps_misfit = 0.0
!
!  ++++++++++++++++++++++++++++++++++++++++++++++++++++
!  Here, we compute the value of the objective function, 
!  using the input kinematic model.
!
   subfault = 0
   delta_freq0 = 1.0/(2.0**lnpt)

   do channel = 1, channels
      delta_freq = delta_freq0/dt_channel(channel)
      forward(:) = z0
      subfault = 0
      do segment = 1, segments
         do iys = 1, nys_sub(segment)
            do ixs = 1, nxs_sub(segment)
               subfault = subfault+1
               subfault_seg = (iys-1)*nxs_sub(segment)+ixs
               rake2 = rake(subfault_seg, segment)*dpi
               a = sin(rake2)*slip(subfault_seg, segment)
               b = cos(rake2)*slip(subfault_seg, segment)
               isl = int((t_rise(subfault_seg, segment)-ta0)/dta+0.5)+1
               isr = int((t_fall(subfault_seg, segment)-ta0)/dta+0.5)+1
               omega = -twopi*delta_freq*rupt_time(subfault_seg, segment)
               z1 = cmplx(cos(omega), sin(omega), double)
               z = cmplx(1.d0, 0.d0, double)
               do i = 1, max_freq
                  forward(i) = forward(i) &
                  & +(a*green_dip(i, channel, subfault)+b*green_stk(i, channel, subfault)) &
                  & *source(i, channel, isl, isr)*z
                  z = z*z1    ! we may need to increase numerical precision
               end do
            end do
         end do
      end do

      do i = 1, wave_pts
         forward_real2(i, channel) = dble(forward(i))
         forward_imag2(i, channel) = aimag(forward(i))
      end do
   end do

   moment0 = 0.0
   kahan_y = 0.0
   kahan_t = 0.0
   kahan_c = 0.0
   do segment = 1, segments
      do k = 1, subfaults_segment(segment)
         kahan_y = slip(k, segment)*shear(k, segment)-kahan_c 
         kahan_t = moment0+kahan_y
         kahan_c = (kahan_t-moment0)-kahan_y
         moment0 = kahan_t
!         moment0 = moment0+slip(k, segment)*shear(k, segment)    ! we may need to increase numerical precision
      end do
   end do

   call define_slip_field(slip, rake)
   call time_laplace(rupt_time, time_reg)
!
!  An iteration of the simulated annealing algorithm, over each subfault.
!
   subfault = 0
!       begin to perturb       
!
   do k = 1, subfaults
      n_subfault(k) = k
   end do

   do k = 1, subfaults-1
      nran = k
      do while (nran .eq. k .or. nran .gt. subfaults)
         x = ran1()
         nran = int(x*(subfaults-k)+k+1)
      end do
      nbb = n_subfault(nran)
      nn = n_subfault(k)
      n_subfault(k) = nbb
      n_subfault(nran) = nn
   end do

   do k = 1, subfaults
      subfault = n_subfault(k)
      if (subfault .gt. subfaults) stop
      n_total = 0
      do i = 1, segments
         n_total = subfaults_segment(i)+n_total
         if (subfault .le. n_total) then
            segment = i
            subfault_seg = subfault
            exit
         end if
      end do
      do i = 1, segment-1
         subfault_seg = subfault_seg-subfaults_segment(i)
      end do
      isl = int((t_rise(subfault_seg, segment)-ta0)/dta+0.5)+1
      isr = int((t_fall(subfault_seg, segment)-ta0)/dta+0.5)+1
      rake2 = rake(subfault_seg, segment)*dpi
      a = sin(rake2)*slip(subfault_seg, segment)
      b = cos(rake2)*slip(subfault_seg, segment)
!
!  make up unchange graph
!
      do channel = 1, channels
         delta_freq = delta_freq0/dt_channel(channel)
         omega = -twopi*delta_freq*rupt_time(subfault_seg, segment)
         z1 = cmplx(cos(omega), sin(omega), double)
         z = cmplx(1.d0, 0.d0, double)
         do i = 1, max_freq
!            omega = -twopi_0*delta_freq*(i-1)*rupt_time(subfault_seg, segment)
!            z = cmplx(cos(omega), sin(omega))
            green_subf = &
            & (a*green_dip(i, channel, subfault)+b*green_stk(i, channel, subfault))* &
            & source(i, channel, isl, isr)*z
!            forward_real(i, channel) = forward_real(i, channel)-real(green_subf)
!            forward_imag(i, channel) = forward_imag(i, channel)-aimag(green_subf)
            forward_real2(i, channel) = forward_real2(i, channel)-real(green_subf)
            forward_imag2(i, channel) = forward_imag2(i, channel)-aimag(green_subf)
            forward_real(i, channel) = real(forward_real2(i, channel))
            forward_imag(i, channel) = real(forward_imag2(i, channel))
            z = z*z1    ! we may need to increase numerical precision
         end do
      end do
!      moment0 = moment0-slip(subfault_seg, segment)*shear(subfault_seg, segment)
      kahan_y = -slip(subfault_seg, segment)*shear(subfault_seg, segment)-kahan_c 
      kahan_t = moment0+kahan_y
      kahan_c = (kahan_t-moment0)-kahan_y
      moment0 = kahan_t
!  
      n_accept = 0
      npb = np(4*(subfault-1)+1)
      if (npb .lt. 2) exit
!
!  slip extreme values
!
      npb = np(4*(subfault-1)+1)
      dpb = dp(4*(subfault-1)+1)
      slip_beg = beg(4*(subfault-1)+1)
      slip_max = (npb-1)*dpb
      slip_end = slip_beg+slip_max
!
!  rake extreme values
!  
      npb = np(4*(subfault-1)+2)
      dpb = dp(4*(subfault-1)+2)
      angle_beg = beg(4*(subfault-1)+2)
      angle_max = (npb-1)*dpb
      angle_end = angle_beg+angle_max
! 
!  rupture time extreme values.
!
      rupt_beg = time_min(subfault_seg, segment)
      rupt_end = time_max(subfault_seg, segment)
      rupt_max = rupt_end-rupt_beg
!
!  rise time parameters extreme values
!  
      rise_time_beg = ta0
      rise_time_end = ta0+(msou-1)*dta
      rise_time_max = (msou-1)*dta
      do i = 1, max_move
!
!       Save values before the perturbation
!
         t_save = rupt_time(subfault_seg, segment)
         d_save = slip(subfault_seg, segment)
         a_save = rake(subfault_seg, segment)
         l_save = t_rise(subfault_seg, segment)
         r_save = t_fall(subfault_seg, segment)
!
!  Perturb the slip
!
         duse = slip_beg - 1.
         do while ((duse .le. slip_beg) .or. (duse .ge. slip_end))
            call cauchy(t, c)                           
            duse = d_save+c*slip_max
         end do
!
!  Perturb the rake
!
         ause = angle_beg - 1.
         do while ((ause .lt. angle_beg) .or. (ause .gt. angle_end))
            call cauchy(t, c)                          
            ause = a_save+c*angle_max
         end do
! 
!  Perturb the rupture time.
!
         vuse = rupt_beg - 0.1
         if (rupt_max .gt. min_dt) then
            do while ((vuse .lt. rupt_beg) .or. (vuse .gt. rupt_end))
               call cauchy(t, c)                       
               vuse = min_dt*int((t_save+c*rupt_max)/min_dt+0.5)     
            end do
         else
            vuse = rupt_beg
         end if             
!
!  Perturb rise time parameters
!  
         isl = 0
         do while (isl .lt. 1 .or. isl .gt. msou)
            call cauchy(t, c)                         
            isl = int((l_save+c*rise_time_max-ta0)/dta+0.5)+1
         end do   
         isr = 0
         do while (isr .lt. 1 .or. isr .gt. msou)
            call cauchy(t, c)                         
            isr = int((r_save+c*rise_time_max-ta0)/dta+0.5)+1
         end do
         
         rake2 = ause*dpi
         a = duse*sin(rake2)
         b = duse*cos(rake2)
         misfit2 = 0.d0
!$omp parallel & 
!$omp& default(shared) &
!$omp& private(channel, delta_freq, j, omega, z, z1, green_subf, cr, cz, forward2, ex)
!$omp do schedule(static) reduction(+:misfit2)
         do channel = 1, channels
            delta_freq = delta_freq0/dt_channel(channel)
            omega = -twopi*delta_freq*vuse
            z1 = cmplx(cos(omega), sin(omega), double) 
            z = cmplx(1.d0, 0.d0, double)
            do j = 1, max_freq
!               omega = -twopi_0*delta_freq*(i-1)*vuse
!               z = cmplx(cos(omega), sin(omega)) 
               green_subf = &
               & (a*green_dip(j, channel, subfault)+b*green_stk(j, channel, subfault))* &
               & source(j, channel, isl, isr)*z
               cr(j) = real(green_subf)+forward_real(j, channel)
               cz(j) = aimag(green_subf)+forward_imag(j, channel)
               z = z*z1    ! we may need to increase numerical precision
            end do
            call wavelet_syn(cr, cz, forward2)
            call misfit_channel(channel, forward2, ex)     
            misfit2 = misfit2 + ex    ! we may need to increase numerical precision
         end do
!$omp end do
!$omp end parallel
         moment0 = moment0+duse*shear(subfault_seg, segment)
         moment = moment0*area
         moment_reg = (moment/moment_input)-1
         if(abs(moment_reg) .ge. 0.10)then
            moment_reg = sqrt(5*abs(moment_reg)+0.5)
         else
            moment_reg = (10*abs(moment_reg))**4
         endif
!         moment_reg = (moment/moment_input)
         amp = 1.0
         call modify_slip_field(subfault, duse, ause)
         call slip_laplace(slip_reg)
         rupt_time(subfault_seg, segment) = vuse
         call time_laplace(rupt_time, time_reg)

         value1 = misfit2+moment_reg*coef_moment+amp*slip_reg*coef_slip
         value1 = value1+coef_time*time_reg+coef_gps*gps_misfit
         moment0 = moment0-duse*shear(subfault_seg, segment)
         de = value1-current_value
!  
!  Now, we update the kinematic model.
!  
         rand = ran1()
         aux = exp(-de/t)
         if (aux .gt. rand) then
            current_value = value1
            slip(subfault_seg, segment) = duse
            rake(subfault_seg, segment) = ause
            rupt_time(subfault_seg, segment) = vuse
            t_rise(subfault_seg, segment) = (isl-1)*dta+ta0
            t_fall(subfault_seg, segment) = (isr-1)*dta+ta0
            n_accept = n_accept+1
         else
            rupt_time(subfault_seg, segment) = t_save
            t_rise(subfault_seg, segment) = l_save
            t_fall(subfault_seg, segment) = r_save
            slip(subfault_seg, segment) = d_save
            rake(subfault_seg, segment) = a_save
         end if
         min_value = min(min_value, value1)
         if (n_accept .gt. accept_max) exit
      end do
!
!  >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
!  finish the perturbation of subevent (segment, subfault_seg)
!
      rake2 = rake(subfault_seg, segment)*dpi
      a = sin(rake2)*slip(subfault_seg, segment)
      b = cos(rake2)*slip(subfault_seg, segment)
      isl = int((t_rise(subfault_seg, segment)-ta0)/dta+0.5)+1
      isr = int((t_fall(subfault_seg, segment)-ta0)/dta+0.5)+1
      kahan_y = slip(subfault_seg, segment)*shear(subfault_seg, segment)-kahan_c 
      kahan_t = moment0+kahan_y
      kahan_c = (kahan_t-moment0)-kahan_y
      moment0 = kahan_t
      d_sub = slip(subfault_seg, segment)
      a_sub = rake(subfault_seg, segment)
      call modify_slip_field(subfault, d_sub, a_sub)
      do channel = 1, channels
         delta_freq = delta_freq0/dt_channel(channel)
         omega = -twopi*delta_freq*rupt_time(subfault_seg, segment)
         z1 = cmplx(cos(omega), sin(omega), double)
         z = cmplx(1.d0, 0.d0, double)
         do i = 1, max_freq
            green_subf = (a*green_dip(i, channel, subfault)+b*green_stk(i, channel, subfault)) &
            &   *source(i, channel, isl, isr)*z
            forward_real2(i, channel) = forward_real2(i, channel)+real(green_subf)
            forward_imag2(i, channel) = forward_imag2(i, channel)+aimag(green_subf)
            forward_real(i, channel) = real(forward_real2(i, channel))
            forward_imag(i, channel) = real(forward_imag2(i, channel))
            z = z*z1
         end do
      end do

   end do
   write(*,*) min_value
   end subroutine annealing_iter3 

   
   subroutine annealing_iter4(slip, rake, rupt_time, t_rise, &
   & t_fall, t, static, insar, ramp)
   implicit none
   integer isl, isr, n_subfault(max_subfaults), n_accept, &
   & nbb, i, k, npb, nn, nran, subfault_seg, segment, channel, subfault, iys, &
   & ixs, n_total, j
   real*8, optional :: ramp(18)
   real slip(:, :), rake(:, :), rupt_time(:, :), &
   & t_fall(:, :), t_rise(:, :), t, &
   & forward_real(wave_pts, max_stations), forward_imag(wave_pts, max_stations), duse, ause, vuse, &
   & de, rand, c, aux, dpb, amp, moment_reg, value1, gps_misfit, insar_misfit, &
   & moment, d_sub, a_sub, slip_reg, a, b, kahan_y, kahan_c, kahan_t, &
   & time_reg, t_save, a_save, d_save, x, moment0, &
   & l_save, r_save, cr(wave_pts2), cz(wave_pts2), forward2(wave_pts2), &
   & slip_beg, slip_max, slip_end, angle_beg, angle_end, angle_max, &
   & rupt_beg, rupt_end, rupt_max, rise_time_beg, rise_time_end, rise_time_max
   real ramp_beg, ramp_end, ramp_max, ramp_use
   real*8 :: ramp0(18), ramp1(18)
   real*8 :: forward_real2(wave_pts, max_stations), forward_imag2(wave_pts, max_stations)
   real*8 :: omega, misfit2, ex
   real :: delta_freq, delta_freq0, rake2!, ex
   complex :: green_subf
   complex*16 :: z, z1, forward(wave_pts), z0
   logical :: static, insar
!
   z0 = cmplx(0.d0, 0.d0, double)
   value1 = 0.0
!
!  ++++++++++++++++++++++++++++++++++++++++++++++++++++
!  Here, we compute the value of the objective function, 
!  using the input kinematic model.
!
   subfault = 0
   delta_freq0 = 1.0/(2.0**lnpt)

   do channel = 1, channels
      delta_freq = delta_freq0/dt_channel(channel)
      forward(:) = z0
      subfault = 0
      do segment = 1, segments
         do iys = 1, nys_sub(segment)
            do ixs = 1, nxs_sub(segment)
               subfault = subfault+1
               subfault_seg = (iys-1)*nxs_sub(segment)+ixs
               rake2 = rake(subfault_seg, segment)*dpi
               a = sin(rake2)*slip(subfault_seg, segment)
               b = cos(rake2)*slip(subfault_seg, segment)
               isl = int((t_rise(subfault_seg, segment)-ta0)/dta+0.5)+1
               isr = int((t_fall(subfault_seg, segment)-ta0)/dta+0.5)+1
               omega = -twopi*delta_freq*rupt_time(subfault_seg, segment)
               z1 = cmplx(cos(omega), sin(omega), double)
               z = cmplx(1.d0, 0.d0, double)
               do i = 1, max_freq
                  forward(i) = forward(i) &
                  & +(a*green_dip(i, channel, subfault)+b*green_stk(i, channel, subfault)) &
                  & *source(i, channel, isl, isr)*z
                  z = z*z1    ! we may need to increase numerical precision
               end do
            end do
         end do
      end do

      do i = 1, wave_pts
         forward_real2(i, channel) = dble(forward(i))
         forward_imag2(i, channel) = aimag(forward(i))
      end do
   end do
   if (static) call static_synthetic(slip, rake, subfaults_segment, gps_misfit)
   if (insar) then
      if (present(ramp)) then
         call insar_synthetic(slip, rake, subfaults_segment, insar_misfit, ramp)
      else
         call insar_synthetic(slip, rake, subfaults_segment, insar_misfit)
      endif
   endif
   moment0 = 0.0
   kahan_y = 0.0
   kahan_t = 0.0
   kahan_c = 0.0
   do segment = 1, segments
      do k = 1, subfaults_segment(segment)
         kahan_y = slip(k, segment)*shear(k, segment)-kahan_c 
         kahan_t = moment0+kahan_y
         kahan_c = (kahan_t-moment0)-kahan_y
         moment0 = kahan_t
!         moment0 = moment0+slip(k, segment)*shear(k, segment)    ! we may need to increase numerical precision
      end do
   end do

   call define_slip_field(slip, rake)
   call time_laplace(rupt_time, time_reg)
!
!  An iteration of the simulated annealing algorithm, over each subfault.
!
   subfault = 0
!       begin to perturb       
!
   do k = 1, subfaults
      n_subfault(k) = k
   end do

   do k = 1, subfaults-1
      nran = k
      do while (nran .eq. k .or. nran .gt. subfaults)
         x = ran1()
         nran = int(x*(subfaults-k)+k+1)
      end do
      nbb = n_subfault(nran)
      nn = n_subfault(k)
      n_subfault(k) = nbb
      n_subfault(nran) = nn
   end do

   do k = 1, subfaults
      subfault = n_subfault(k)
      if (subfault .gt. subfaults) stop
      n_total = 0
      do i = 1, segments
         n_total = subfaults_segment(i)+n_total
         if (subfault .le. n_total) then
            segment = i
            subfault_seg = subfault
            exit
         end if
      end do
      do i = 1, segment-1
         subfault_seg = subfault_seg-subfaults_segment(i)
      end do
      d_sub = slip(subfault_seg, segment)
      a_sub = rake(subfault_seg, segment)
      isl = int((t_rise(subfault_seg, segment)-ta0)/dta+0.5)+1
      isr = int((t_fall(subfault_seg, segment)-ta0)/dta+0.5)+1
      rake2 = a_sub*dpi
      a = sin(rake2)*d_sub
      b = cos(rake2)*d_sub
!
!  make up unchange graph
!
      do channel = 1, channels
         delta_freq = delta_freq0/dt_channel(channel)
         omega = -twopi*delta_freq*rupt_time(subfault_seg, segment)
         z1 = cmplx(cos(omega), sin(omega), double)
         z = cmplx(1.d0, 0.d0, double)
         do i = 1, max_freq
!            omega = -twopi_0*delta_freq*(i-1)*rupt_time(subfault_seg, segment)
!            z = cmplx(cos(omega), sin(omega))
            green_subf = &
            &  (a*green_dip(i, channel, subfault)+b*green_stk(i, channel, subfault)) &
            &  *source(i, channel, isl, isr)*z
            forward_real2(i, channel) = forward_real2(i, channel)-real(green_subf)
            forward_imag2(i, channel) = forward_imag2(i, channel)-aimag(green_subf)
            forward_real(i, channel) = real(forward_real2(i, channel))
            forward_imag(i, channel) = real(forward_imag2(i, channel))
            z = z*z1    ! we may need to increase numuerical precision
         end do
      end do
      if (static) call static_remove_subfault(d_sub, a_sub, segment, subfault_seg)
      if (insar) call insar_remove_subfault(d_sub, a_sub, segment, subfault_seg)
      kahan_y = -slip(subfault_seg, segment)*shear(subfault_seg, segment)-kahan_c 
      kahan_t = moment0+kahan_y
      kahan_c = (kahan_t-moment0)-kahan_y
      moment0 = kahan_t
!  
      n_accept = 0
      npb = np(4*(subfault-1)+1)
      if (npb .lt. 2) exit
!
!  slip extreme values
!
      npb = np(4*(subfault-1)+1)
      dpb = dp(4*(subfault-1)+1)
      slip_beg = beg(4*(subfault-1)+1)
      slip_max = (npb-1)*dpb
      slip_end = slip_beg+slip_max
!
!  rake extreme values
!  
      npb = np(4*(subfault-1)+2)
      dpb = dp(4*(subfault-1)+2)
      angle_beg = beg(4*(subfault-1)+2)
      angle_max = (npb-1)*dpb
      angle_end = angle_beg+angle_max
! 
!  rupture time extreme values.
!
      rupt_beg = time_min(subfault_seg, segment)
      rupt_end = time_max(subfault_seg, segment)
      rupt_max = rupt_end-rupt_beg
!
!  rise time parameters extreme values
!  
      rise_time_beg = ta0
      rise_time_end = ta0+(msou-1)*dta
      rise_time_max = (msou-1)*dta
      do i = 1, max_move
!
!       Save values before the perturbation
!
         t_save = rupt_time(subfault_seg, segment)
         d_save = slip(subfault_seg, segment)
         a_save = rake(subfault_seg, segment)
         l_save = t_rise(subfault_seg, segment)
         r_save = t_fall(subfault_seg, segment)
!
!  Perturb the slip
!
         duse = slip_beg - 1.
         do while ((duse .le. slip_beg) .or. (duse .ge. slip_end))
            call cauchy(t, c)                           
            duse = d_save+c*slip_max
         end do
!
!  Perturb the rake
!
         ause = angle_beg - 1.
         do while ((ause .lt. angle_beg) .or. (ause .gt. angle_end))
            call cauchy(t, c)                          
            ause = a_save+c*angle_max
         end do
! 
!  Perturb the rupture time.
!
         vuse = rupt_beg - 0.1
         if (rupt_max .gt. min_dt) then
            do while ((vuse .lt. rupt_beg) .or. (vuse .gt. rupt_end))
               call cauchy(t, c)                       
               vuse = min_dt*int((t_save+c*rupt_max)/min_dt+0.5)     
            end do
         else
            vuse = rupt_beg
         end if             
!
!  Perturb rise time parameters
!  
         isl = 0
         do while (isl .lt. 1 .or. isl .gt. msou)
            call cauchy(t, c)                         
            isl = int((l_save+c*rise_time_max-ta0)/dta+0.5)+1
         end do   
         isr = 0
         do while (isr .lt. 1 .or. isr .gt. msou)
            call cauchy(t, c)                         
            isr = int((r_save+c*rise_time_max-ta0)/dta+0.5)+1
         end do
         
         rake2 = ause*dpi
         a = duse*sin(rake2)
         b = duse*cos(rake2)
         misfit2 = 0.d0
!$omp parallel & 
!$omp& default(shared) &
!$omp& private(channel, delta_freq, j, omega, z, z1, green_subf, cr, cz, forward2, ex)
!$omp do schedule(static) reduction(+:misfit2)
         do channel = 1, channels
            delta_freq = delta_freq0/dt_channel(channel)
            omega = -twopi*delta_freq*vuse
            z1 = cmplx(cos(omega), sin(omega), double)
            z = cmplx(1.d0, 0.d0, double)
            do j = 1, max_freq
               green_subf = &
               &  (a*green_dip(j, channel, subfault)+b*green_stk(j, channel, subfault)) &
               &  *source(j, channel, isl, isr)*z
               cr(j) = real(green_subf)+forward_real(j, channel)
               cz(j) = aimag(green_subf)+forward_imag(j, channel)
               z = z*z1    ! we may need to increase numerical precision
            end do
            call wavelet_syn(cr, cz, forward2)
            call misfit_channel(channel, forward2, ex)     
            misfit2 = misfit2 + ex    ! we may need to increase numerical precision
         end do
!$omp end do
!$omp end parallel
         moment0 = moment0+duse*shear(subfault_seg, segment)
         moment = moment0*area
         moment_reg = (moment/moment_input) - 1
         if(abs(moment_reg) .ge. 0.10)then
            moment_reg = sqrt(5*abs(moment_reg)+0.5)
         else
            moment_reg = (10*abs(moment_reg))**4
         endif
!         moment_reg = (moment/moment_input)
         amp = 1.0
         if (static) call static_modify_subfault(duse, ause, segment, subfault_seg, gps_misfit)
         if (insar) call insar_modify_subfault(duse, ause, segment, subfault_seg, insar_misfit)
         call modify_slip_field(subfault, duse, ause)
         call slip_laplace(slip_reg)
         rupt_time(subfault_seg, segment) = vuse
         call time_laplace(rupt_time, time_reg)

         value1 = misfit2+moment_reg*coef_moment+amp*slip_reg*coef_slip
         value1 = value1+coef_time*time_reg
         value1 = value1+coef_gps*gps_misfit+coef_insar*insar_misfit
         moment0 = moment0-duse*shear(subfault_seg, segment)
         de = value1-current_value
!  
!  Now, we update the kinematic model.
!  
         rand = ran1()
         aux = exp(-de/t)
         if (aux .gt. rand) then
            current_value = value1
            insar_misfit0 = insar_misfit
            slip(subfault_seg, segment) = duse
            rake(subfault_seg, segment) = ause
            rupt_time(subfault_seg, segment) = vuse
            t_rise(subfault_seg, segment) = (isl-1)*dta+ta0
            t_fall(subfault_seg, segment) = (isr-1)*dta+ta0
            n_accept = n_accept+1
         else
            rupt_time(subfault_seg, segment) = t_save
            t_rise(subfault_seg, segment) = l_save
            t_fall(subfault_seg, segment) = r_save
            slip(subfault_seg, segment) = d_save
            rake(subfault_seg, segment) = a_save
         end if
         min_value = min(min_value, value1)
         if (n_accept .gt. accept_max) exit
      end do
!
!  >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
!  finish the perturbation of subevent (segment, subfault_seg)
!
      rake2 = rake(subfault_seg, segment)*dpi
      a = sin(rake2)*slip(subfault_seg, segment)
      b = cos(rake2)*slip(subfault_seg, segment)
      isl = int((t_rise(subfault_seg, segment)-ta0)/dta+0.5)+1
      isr = int((t_fall(subfault_seg, segment)-ta0)/dta+0.5)+1
      kahan_y = slip(subfault_seg, segment)*shear(subfault_seg, segment)-kahan_c 
      kahan_t = moment0+kahan_y
      kahan_c = (kahan_t-moment0)-kahan_y
      moment0 = kahan_t
      d_sub = slip(subfault_seg, segment)
      a_sub = rake(subfault_seg, segment)
      call modify_slip_field(subfault, d_sub, a_sub)
      do channel = 1, channels
         delta_freq = delta_freq0/dt_channel(channel)
         omega = -twopi*delta_freq*rupt_time(subfault_seg, segment)
         z1 = cmplx(cos(omega), sin(omega), double)   
         z = cmplx(1.d0, 0.d0, double)
         do i = 1, max_freq
            green_subf = (a*green_dip(i, channel, subfault)+b*green_stk(i, channel, subfault)) &
            &   *source(i, channel, isl, isr)*z
            forward_real2(i, channel) = forward_real2(i, channel)+real(green_subf)
            forward_imag2(i, channel) = forward_imag2(i, channel)+aimag(green_subf)
            forward_real(i, channel) = real(forward_real2(i, channel))
            forward_imag(i, channel) = real(forward_imag2(i, channel))
            z = z*z1
         end do
      end do
      if (static) call static_add_subfault(d_sub, a_sub, segment, subfault_seg)
      if (insar) call insar_add_subfault(d_sub, a_sub, segment, subfault_seg)
   end do

!
! For insar, now we add ramp perturbation
!
   if (insar) then
      if (present(ramp)) then 
         call insar_remove_ramp(ramp)
         n_accept = 0
!
!  ramp parameters extreme values
!  
         ramp_beg = -20
         ramp_end = 20
         ramp_max = 40
         do i = 1, max_move
!
!       Save values before the perturbation
!
            ramp0(:) = ramp(:)
            ramp1(:) = ramp(:)
!
!  Perturb ramp parameters
!  
            do j = 1, ramp_length
               ramp_use = ramp_beg - 1.
               do while ((ramp_use .lt. ramp_beg) .or. (ramp_use .gt. ramp_end))
                  call cauchy(t, c)
                  ramp_use = ramp1(j)+c*ramp_max
               end do
               ramp1(j) = ramp_use
            end do
            
            call insar_modify_ramp(ramp1, insar_misfit)
            de = insar_misfit-insar_misfit0
!  
!  Now, we update the ramp.
!  
            rand = ran1()
            aux = exp(-de/t)
            if (aux .gt. rand) then
               current_value = current_value + coef_insar*(insar_misfit - insar_misfit0)
               insar_misfit0 = insar_misfit
               ramp(:) = ramp1(:)
               n_accept = n_accept+1
            else
               ramp(:) = ramp0(:)
            end if
            if (n_accept .gt. accept_max) exit
         end do
         min_value = min(min_value, current_value)
!
!  >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
!  finish the perturbation of ramp
!
         call insar_add_ramp(ramp)
      end if
   end if

   write(*,*) min_value
   end subroutine annealing_iter4


end module annealing 
