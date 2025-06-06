module glc_comp_nuopc

  !----------------------------------------------------------------------------
  ! This is the NUOPC cap for CISM
  !----------------------------------------------------------------------------

  use ESMF
  use NUOPC               , only : NUOPC_CompDerive, NUOPC_CompSetEntryPoint, NUOPC_CompSpecialize
  use NUOPC               , only : NUOPC_CompFilterPhaseMap, NUOPC_CompAttributeGet, NUOPC_CompAttributeSet
  use NUOPC_Model         , only : model_routine_SS           => SetServices
  use NUOPC_Model         , only : SetVM
  use NUOPC_Model         , only : model_routine_Run          => routine_Run
  use NUOPC_Model         , only : model_label_Advance        => label_Advance
  use NUOPC_Model         , only : model_label_DataInitialize => label_DataInitialize
  use NUOPC_Model         , only : model_label_SetRunClock    => label_SetRunClock
  use NUOPC_Model         , only : model_label_Finalize       => label_Finalize
  use NUOPC_Model         , only : NUOPC_ModelGet
  use shr_sys_mod         , only : shr_sys_abort
  use shr_cal_mod         , only : shr_cal_ymd2date
  use shr_kind_mod        , only : r8 => shr_kind_r8, cl=>shr_kind_cl, cs=>shr_kind_cs
  use shr_string_mod      , only : shr_string_listGetNum, shr_string_listGetName
  use glc_import_export   , only : advertise_fields, realize_fields, export_fields, import_fields
  use glc_import_export   , only : get_num_icesheets
  use glc_constants       , only : verbose, stdout, model_doi_url, num_icesheets, icesheet_names
  use glc_InitMod         , only : glc_initialize
  use glc_RunMod          , only : glc_run
  use glc_FinalMod        , only : glc_final
  use glc_io              , only : glc_io_write_restart
  use glc_communicate     , only : init_communicate, my_task, master_task
  use glc_time_management , only : iyear,imonth,iday,ihour,iminute,isecond,runtype
  use glc_fields          , only : ice_sheet
  use glc_indexing        , only : local_to_global_indices
  use glc_indexing        , only : get_npts, get_nx, get_ny, spatial_to_vector
  use glc_ensemble        , only : set_inst_vars
  use glc_files           , only : set_filenames, ionml_filename
  use glad_main           , only : glad_get_lat_lon
  use nuopc_shr_methods   , only : chkerr, state_setscalar, state_getscalar, state_diagnose, alarmInit
  use nuopc_shr_methods   , only : set_component_logging, get_component_instance, log_clock_advance
  use perf_mod            , only : t_startf, t_stopf, t_barrierf
!$ use omp_lib            , only : omp_set_num_threads
  implicit none
  private ! except

  ! Module routines
  public  :: SetServices
  public  :: SetVM
  private :: InitializeP0
  private :: InitializeAdvertise
  private :: InitializeRealize
  private :: ModelSetRunClock
  private :: ModelAdvance
  private :: ModelFinalize

  !--------------------------------------------------------------------------
  ! Private module data
  !--------------------------------------------------------------------------

  logical                    :: cism_evolve
  character(ESMF_MAXSTR)     :: mesh_glc_list ! colon-delimited list of meshes
  integer                    :: lmpicom
  character(len=16)          :: inst_name ! full name of current instance (in the CESM multi-instance/ensemble sense; e.g., GLC_0001)
  integer, parameter         :: dbug = 1
  integer                    :: nthrds  ! Number of openMP threads per mpi task
  character(len=*),parameter :: modName =  "(glc_comp_nuopc)"
  character(len=*),parameter :: u_FILE_u = &
       __FILE__

!===============================================================================
contains
!===============================================================================

  subroutine SetServices(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    character(len=*),parameter  :: subname=trim(modName)//':(SetServices) '

    rc = ESMF_SUCCESS
    if (dbug > 5) then
       call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO)
    end if

    ! the NUOPC gcomp component will register the generic methods
    call NUOPC_CompDerive(gcomp, model_routine_SS, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    ! switching to IPD versions
    call ESMF_GridCompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
         userRoutine=InitializeP0, phase=0, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    ! set entry point for methods that require specific implementation
    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
         phaseLabelList=(/"IPDv01p1"/), userRoutine=InitializeAdvertise, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
         phaseLabelList=(/"IPDv01p3"/), userRoutine=InitializeRealize, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    ! attach specializing method(s)
    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_Advance, &
         specRoutine=ModelAdvance, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    call ESMF_MethodRemove(gcomp, label=model_label_SetRunClock, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_SetRunClock, &
         specRoutine=ModelSetRunClock, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_Finalize, &
         specRoutine=ModelFinalize, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    if (dbug > 5) then
       call ESMF_LogWrite(subname//' done', ESMF_LOGMSG_INFO)
    end if

  end subroutine SetServices

  !===============================================================================

  subroutine InitializeP0(gcomp, importState, exportState, clock, rc)

    ! input/output variables
    type(ESMF_GridComp)   :: gcomp
    type(ESMF_State)      :: importState, exportState
    type(ESMF_Clock)      :: clock
    integer, intent(out)  :: rc
    !-------------------------------------------------------------------------------

    rc = ESMF_SUCCESS

    ! Switch to IPDv01 by filtering all other phaseMap entries
    call NUOPC_CompFilterPhaseMap(gcomp, ESMF_METHOD_INITIALIZE, acceptStringList=(/"IPDv01p"/), rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

  end subroutine InitializeP0

  !===============================================================================

  subroutine InitializeAdvertise(gcomp, importState, exportState, clock, rc)

    ! uses

    ! input/output variables
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    ! local variables
    type(ESMF_VM)          :: vm
    character(ESMF_MAXSTR) :: cvalue
    logical                :: isPresent, isSet
    integer                :: localpet
    integer                :: shrlogunit  ! original log unit
    integer                :: i,j,n
    character(len=CL)      :: logmsg
    integer                :: inst_index    ! number of current instance (in the CESM multi-instance/ensemble sense; e.g., 1)
    character(len=16)      :: inst_suffix   ! character string associated with instance number
    logical                :: glc_coupled_fluxes ! are we sending fluxes to other components?
    integer                :: num_icesheets_from_mediator ! number of icesheets in this run
    character(len=*), parameter :: subname=trim(modName)//':(InitializeAdvertise) '
    character(len=*), parameter :: format = "('("//trim(subname)//") :',A)"
    !-------------------------------------------------------------------------------

    rc = ESMF_SUCCESS
    if (dbug > 5) then
       call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO)
    end if

    ! generate local mpi comm
    call ESMF_GridCompGet(gcomp, vm=vm, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    call ESMF_VMGet(vm, mpiCommunicator=lmpicom, localpet=localpet, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    ! initialize CISM MPI stuff
    call init_communicate(lmpicom)

    ! reset shr logging to my log file
    call set_component_logging(gcomp, localPet==0, stdout, shrlogunit, rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    ! determine instance information
    ! the following sets the module instance variables in glc_ensemble
    call get_component_instance(gcomp, inst_suffix, inst_index, rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    inst_name = "GLC"//trim(inst_suffix)
    call set_inst_vars(inst_index, inst_name, inst_suffix )

    ! Set filenames which depend on instance information
    call set_filenames()

    ! Determine if cism will evolve - if not will not import any fields from the mediator
    call NUOPC_CompAttributeGet(gcomp, name="cism_evolve", value=cvalue, isPresent=isPresent, isSet=isSet, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    if (isPresent .and. isSet) then
       read(cvalue,*) cism_evolve
       call ESMF_LogWrite(trim(subname)//' cism_evolve = '//trim(cvalue), ESMF_LOGMSG_INFO)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
    else
       call shr_sys_abort(subname//'Need to set cism_evolve')
    endif

    ! Get colon delimited string of mesh filenames
    call NUOPC_CompAttributeGet(gcomp, name='mesh_glc', value=mesh_glc_list, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    num_icesheets_from_mediator = shr_string_listGetNum(mesh_glc_list)
    if (my_task == master_task) then
       write(stdout,'(a,i4)')'number of ice sheets is ',num_icesheets_from_mediator
    end if

    ! Advertise fields
    call advertise_fields(gcomp, cism_evolve, num_icesheets_from_mediator, rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    if (dbug > 5) then
       call ESMF_LogWrite(subname//' done', ESMF_LOGMSG_INFO)
    end if

  end subroutine InitializeAdvertise

  !===============================================================================

  subroutine InitializeRealize(gcomp, importState, exportState, clock, rc)

    ! input/output variables
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState
    type(ESMF_State)     :: exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    ! local variables
    type(ESMF_Mesh), allocatable :: mesh(:)          ! esmf meshes for ice sheets
    type(ESMF_DistGrid), allocatable :: DistGrid(:)  ! esmf global index space descriptor, per ice sheet
    type(ESMF_Time)         :: currTime              ! Current time
    type(ESMF_Time)         :: startTime             ! Start time
    type(ESMF_Time)         :: stopTime              ! Stop time
    type(ESMF_TimeInterval) :: timeStep              ! Model timestep
    type(ESMF_CalKind_Flag) :: esmf_caltype          ! esmf calendar type
    type(ESMF_vm)           :: vm                    ! esmf virtual machine structure
    integer                 :: ref_tod               ! reference time of day (sec)
    integer                 :: yy,mm,dd              ! Temporaries for time query
    integer                 :: start_ymd             ! start date (YYYYMMDD)
    integer                 :: start_tod             ! start time of day (sec)
    integer                 :: stop_ymd              ! stop date (YYYYMMDD)
    integer                 :: stop_tod              ! stop time of day (sec)
    integer                 :: curr_ymd              ! Start date (YYYYMMDD)
    integer                 :: curr_tod              ! Start time of day (sec)
    character(ESMF_MAXSTR)  :: cvalue                ! config data
    character(ESMF_MAXSTR)  :: mesh_glc_filename     ! mesh filename for kth icesheet
    integer                 :: g,n                   ! indices
    character(len=CL)       :: caseid                ! case identifier name
    character(len=CL)       :: starttype             ! start-type (startup, continue, branch, hybrid)
    character(len=CL)       :: calendar              ! calendar type name
    integer                 :: lbnum                 ! input to memory diagnostic
    integer                 :: spatialDim
    integer                 :: numOwnedElements
    real(r8), pointer       :: ownedElemCoords(:)
    real(r8), pointer       :: mesh_lons(:), lons(:,:), lons_vec(:)
    real(r8), pointer       :: mesh_lats(:), lats(:,:), lats_vec(:)
    real(r8)                :: tolerance = 1.e-5_r8
    integer                 :: elementCount
    integer                 :: localPet
    integer                 :: i,j,ns
    integer                 :: npts,nx,ny
    integer, allocatable    :: gindex(:)
    integer                 :: num_icesheets_from_mediator
    character(*), parameter :: F00   = "('(InitializeRealize) ',8a)"
    character(*), parameter :: F01   = "('(InitializeRealize) ',a,8i8)"
    character(*), parameter :: F91   = "('(InitializeRealize) ',73('-'))"
    character(len=*),parameter :: subname=trim(modName)//':(InitializeRealize) '
    !-------------------------------------------------------------------------------

    rc = ESMF_SUCCESS
    if (dbug > 5) then
       call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO)
    end if

#if (defined _MEMTRACE)
    if (my_task == master_task) then
       lbnum=1
       call memmon_dump_fort('memmon.out','glc_comp_nuopc_InitializeRealize:start::',lbnum)
    endif
#endif

    !--------------------------------
    ! Initialize GLC
    !--------------------------------

    ! Determine caseid
    call NUOPC_CompAttributeGet(gcomp, name='case_name', value=cvalue, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    read(cvalue,*) caseid

    ! Determine start type
    call NUOPC_CompAttributeGet(gcomp, name='start_type', value=cvalue, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    read(cvalue,*) starttype

    ! Determine openmp threading
    call ESMF_GridCompGet(gcomp, vm=vm, localPet=localPet, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    call ESMF_VMGet(vm, pet=localPet, peCount=nthrds, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    if(nthrds==1) then
       call NUOPC_CompAttributeGet(gcomp, "nthreads", value=cvalue, rc=rc)
       if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, line=__LINE__, file=u_FILE_u)) return
       read(cvalue,*) nthrds
    endif
!$  call omp_set_num_threads(nthrds)

    if (cism_evolve) then
       if (     trim(starttype) == trim('startup')) then
          runtype = 'initial'
       else if (trim(starttype) == trim('continue')) then
          runtype='continue'
       else if (trim(starttype) == trim('branch')) then
          runtype='branch'
       else
          call shr_sys_abort(subname//' ERROR: unknown starttype' )
       end if
    else
       ! NOTE: with the NUOPC interface, the CISM run phase is never called when running
       ! in noevolve mode, so a restart file will never be written for CISM. Since we
       ! don't have a restart file to start from, we need to tell CISM to start in
       ! startup/initial mode in this situation.
       !
       ! Note that this looks at the overall cism_evolve, which is only .false. if no ice
       ! sheets are evolving: In the situation where one ice sheet is evolving but another
       ! is not, the overall cism_evolve will be .true. and restart files will still be
       ! written for every ice sheet (even non-evolving ones), so we can safely restart
       ! from these restart files (so we do not need to force runtype to "initial").
       if (my_task == master_task) then
          write(stdout,*)' GLC cism is not evolving, runtype is always set to initial'
       end if
       runtype = 'initial'
    end if

    ! Get properties from clock
    call ESMF_ClockGet( clock, &
         currTime=currTime, startTime=startTime, stopTime=stopTime, timeStep=timeStep, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    call ESMF_TimeGet( startTime, yy=yy, mm=mm, dd=dd, s=start_tod, rc=rc )
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    call shr_cal_ymd2date(yy,mm,dd,start_ymd)
    call ESMF_TimeGet( currTime, yy=yy, mm=mm, dd=dd, s=curr_tod, rc=rc )
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    call shr_cal_ymd2date(yy,mm,dd,curr_ymd)
    call ESMF_TimeGet( stopTime, yy=yy, mm=mm, dd=dd, s=stop_tod, rc=rc )
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    call shr_cal_ymd2date(yy,mm,dd,stop_ymd)
    call ESMF_TimeGet( currTime, calkindflag=esmf_caltype, rc=rc )
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    if (esmf_caltype == ESMF_CALKIND_NOLEAP) then
       ! do nothing
    else if (esmf_caltype == ESMF_CALKIND_GREGORIAN) then
       ! do nothing
    else
       call shr_sys_abort( subname//'ERROR:: bad calendar for ESMF' )
    end if

    ! Initialize GLC
    call glc_initialize(clock)
    if (my_task == master_task) then
       write(stdout,F01) ' GLC Initial Date ',iyear,imonth,iday,ihour,iminute,isecond
       write(stdout,F00) ' Initialize Done'
    endif

    ! TODO (mvertens, 2018-11-28): read in model_doi_url

    !--------------------------------
    ! Realize the actively coupled fields
    !--------------------------------

    ! Consistency checks

    num_icesheets_from_mediator = get_num_icesheets()
    if (num_icesheets_from_mediator /= num_icesheets) then
       write(stdout,*) 'num_icesheets from mediator: ', num_icesheets_from_mediator
       write(stdout,*) 'num_icesheets from cism namelist: ', num_icesheets
       call shr_sys_abort('num_icesheets from mediator differs from number set in cism namelist')
    end if

    ! Allocate and read in mesh array
    allocate(DistGrid(num_icesheets))
    allocate(mesh(num_icesheets))
    do ns = 1,num_icesheets
       ! determine mesh filename
       call shr_string_listGetName(mesh_glc_list, ns, mesh_glc_filename)
       if (my_task == master_task) then
          write(stdout,'(a,i4,a)')'mesh file for ice_sheeet_domain ',ns,' is ',trim(mesh_glc_filename)
       end if

       ! create distGrid from global index array
       gindex = local_to_global_indices(instance_index=ns)
       DistGrid(ns) = ESMF_DistGridCreate(arbSeqIndexList=gindex, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       deallocate(gindex)

       ! read in the ice sheet mesh on the cism decomposition
       mesh(ns) = ESMF_MeshCreate(filename=trim(mesh_glc_filename), fileformat=ESMF_FILEFORMAT_ESMFMESH, &
            elementDistgrid=Distgrid(ns),  rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
    end do

    ! Realize the actively coupled fields
    call realize_fields(gcomp, mesh, rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    !--------------------------------
    ! Check consistency of mesh with internal CISM lats and lons
    !--------------------------------

    do ns = 1,num_icesheets
       npts = get_npts(instance_index=ns)
       nx = get_nx(instance_index=ns)
       ny = get_ny(instance_index=ns)

       ! obtain mesh lats and lons
       call ESMF_MeshGet(mesh(ns), spatialDim=spatialDim, numOwnedElements=numOwnedElements, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       if (numOwnedElements /= npts) then
          call shr_sys_abort('ERROR: numOwnedElements is not equal to npts')
       end if

       allocate(ownedElemCoords(spatialDim*numOwnedElements))
       call ESMF_MeshGet(mesh(ns), ownedElemCoords=ownedElemCoords, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       allocate(mesh_lons(numOwnedElements))
       allocate(mesh_lats(numOwnedElements))
       do n = 1,npts
          mesh_lons(n) = ownedElemCoords(2*n-1)
          mesh_lats(n) = ownedElemCoords(2*n)
       end do

       ! obtain CISM internal mesh lats and lons
       allocate(lats(nx,ny))
       allocate(lons(nx,ny))
       allocate(lats_vec(npts))
       allocate(lons_vec(npts))
       call glad_get_lat_lon(ice_sheet, instance_index = ns, lats = lats, lons = lons)
       call spatial_to_vector(instance_index = ns, &
            arr_spatial = lons, &
            arr_vector = lons_vec)
       call spatial_to_vector(instance_index = ns, &
            arr_spatial = lats, &
            arr_vector = lats_vec)

       ! check lats and lons from the mesh are not different to a tolerance factor
       ! from lats and lons calculated internally
       do n = 1, npts
          if ( abs(mesh_lons(n) - lons_vec(n)) > tolerance) then
             write(stdout,'(a,i8,2x,3(d13.5,2x))')'ERROR: CISM lon check: n, lon, mesh_lon, lon_diff = ',&
                  n, lons_vec(n), mesh_lons(n),abs(mesh_lons(n)-lons_vec(n))
             call shr_sys_abort()
          end if
          if (abs(mesh_lats(n) - lats_vec(n)) > tolerance) then
             write(stdout,'(a,i8,2x,3(d13.5,2x))')'ERROR: CISM lat check: n, lat, mesh_lat, lat_diff = ',&
                  n, lats_vec(n), mesh_lats(n),abs(mesh_lats(n)-lats_vec(n))
             call shr_sys_abort()
          end if
       end do
       deallocate(mesh_lons, mesh_lats)
       deallocate(lons, lats)
       deallocate(lons_vec, lats_vec)
    end do

    !--------------------------------
    ! Create glc export state
    !--------------------------------

    ! TODO (mvertens, 2019-06-02): For now assume that all fields in export state are sent - but this is really
    ! not needed for TG compsets - but still need to send nx and ny on initialization - maybe should have these
    ! read in by the mediator?
    call export_fields(exportState, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    ! Write diagnostics if appropriate
    if (my_task == master_task) then
       write(stdout,F91)
       write(stdout,F00) trim(inst_name),': start of main integration loop'
       write(stdout,F91)
    end if
    if (dbug > 1) then
       call State_diagnose(exportState,subname//':ES',rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
    endif

#if (defined _MEMTRACE)
    if(my_task == master_task) then
       write(stdout,*) TRIM(Sub) // ':end::'
       lbnum=1
       call memmon_dump_fort('memmon.out','glc_comp_nuopc_InitializeRealize:end::',lbnum)
       call memmon_reset_addr()
    endif
#endif

    if (dbug > 5) then
       call ESMF_LogWrite(subname//' done', ESMF_LOGMSG_INFO)
    end if

  end subroutine InitializeRealize

  !===============================================================================

  subroutine ModelAdvance(gcomp, rc)

    !------------------------
    ! Run CISM
    !------------------------

    ! arguments:
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    ! local variables:
    type(ESMF_clock)       :: clock
    type(ESMF_STATE)       :: importState
    type(ESMF_STATE)       :: exportState
    type(ESMF_Time)        :: NextTime
    type(ESMF_Alarm)       :: alarm
    type(ESMF_Time)        :: currtime
    integer                :: glcYMD       ! glc model date
    integer                :: glcTOD       ! glc model sec
    integer                :: cesmYMD      ! cesm model date
    integer                :: cesmTOD      ! cesm model sec
    integer                :: cesmYR       ! cesm model year
    integer                :: cesmMON      ! cesm model month
    integer                :: cesmDAY      ! cesm model day
    integer                :: ns           ! index
    logical                :: done         ! time loop logical
    logical                :: valid_inputs ! if true, inputs from mediator are valid
    character(ESMF_MAXSTR) :: cvalue
    character(*), parameter :: F01   = "('(glc_comp_nuopc: ModelAdvance) ',a,8i8)"
    character(*), parameter :: subName = "(glc_comp_nuopc: ModelAdvance) "
    !----------------------------------------------------------------

    rc = ESMF_SUCCESS
    if (dbug > 5) then
       call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO)
    end if

!$  call omp_set_num_threads(nthrds)

    !--------------------------------
    ! Obtain the CISM internal time
    !--------------------------------

    glcYMD = iyear*10000 + imonth*100 + iday
    glcTOD = ihour*3600 + iminute*60 + isecond
    if (my_task == master_task) then
       write(stdout,F01) ' Clock at beginning of time step ',glcYMD,glcTOD
    endif

    !--------------------------------
    ! Query the Component for its clock at the next time step
    !--------------------------------

    call NUOPC_ModelGet(gcomp, modelClock=clock, importState=importState, exportState=exportState, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    ! Need to get the next time here since the clock in the nuopc driver does not get advanced until the end
    ! of the time loop and in the mct case it was advanced in the beginning
    call ESMF_ClockGetNextTime(clock, nextTime=nextTime, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    call ESMF_TimeGet( NextTime, yy=cesmYR, mm=cesmMON, dd=cesmDAY, s=cesmTOD, rc=rc )
    if ( rc /= ESMF_SUCCESS ) call shr_sys_abort("ERROR: glc_io_write_restart")

    call shr_cal_ymd2date(cesmYR, cesmMON, cesmDAY, cesmYMD)
    if (my_task == master_task) then
       write(stdout,F01) ' Clock at end of run step ',cesmYMD, cesmTOD
    endif

    !--------------------------------
    ! Unpack import state
    !--------------------------------

    call import_fields(rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    !--------------------------------
    ! Run CISM
    !--------------------------------

    ! NOTE: in mct the cesmYMD is advanced at the beginning of the time loop

    ! Determine if inputs from mediator are valid
    call ESMF_ClockGetAlarm(clock, alarmname='alarm_valid_inputs', alarm=alarm, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    if (ESMF_AlarmIsRinging(alarm, rc=rc)) then
       valid_inputs = .true.
       call ESMF_AlarmRingerOff( alarm, rc=rc )
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
    else
       valid_inputs = .false.
    endif
    write(cvalue,*) valid_inputs
    call ESMF_LogWrite(subname//' valid_input for cism is '//trim(cvalue), ESMF_LOGMSG_INFO)
    if (my_task == master_task) then
       write(stdout,*)' valid_input for cism is ',valid_inputs
    end if

    done = .false.
    if (glcYMD == cesmYMD .and. glcTOD == cesmTOD) done = .true.
    do while (.not. done)
       if (glcYMD > cesmYMD .or. (glcYMD == cesmYMD .and. glcTOD > cesmTOD)) then
          write(stdout,*) subname,' ERROR overshot coupling time ',glcYMD,glcTOD,cesmYMD,cesmTOD
          call shr_sys_abort('glc error overshot time')
       endif

       ! To be consistent with mct - advance the model clock here so
       ! that the history output is consistent
       call ESMF_ClockAdvance(clock,rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return

       call glc_run(clock, valid_inputs)

       glcYMD = iyear*10000 + imonth*100 + iday
       glcTOD = ihour*3600 + iminute*60 + isecond
       if (glcYMD == cesmYMD .and. glcTOD == cesmTOD) done = .true.
       if (verbose .and. my_task == master_task) then
          write(stdout,F01) ' GLC  Date ',glcYMD,glcTOD
       endif

    enddo

    !--------------------------------
    ! Pack export state if appropriate
    !--------------------------------

    call export_fields(exportState, rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    ! If time to write restart, do so
    call ESMF_ClockGetAlarm(clock, alarmname='alarm_restart', alarm=alarm, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return
    if (ESMF_AlarmIsRinging(alarm, rc=rc)) then
       do ns = 1, num_icesheets
          call glc_io_write_restart(ice_sheet%instances(ns), icesheet_names(ns), clock)
       end do
       call ESMF_AlarmRingerOff( alarm, rc=rc )
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
    endif

  end subroutine ModelAdvance

  !===============================================================================

  subroutine ModelSetRunClock(gcomp, rc)

    ! input/output variables
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    ! local variables
    type(ESMF_Clock)         :: mclock         ! model clock
    type(ESMF_Clock)         :: dclock         ! driver clock
    type(ESMF_Time)          :: mcurrtime      ! model current time
    type(ESMF_Time)          :: mstarttime     ! model start time
    type(ESMF_Time)          :: dcurrtime      ! driver current time
    type(ESMF_TimeInterval)  :: mtimestep      ! model time step
    type(ESMF_TimeInterval)  :: dtimestep      ! driver time step
    type(ESMF_Time)          :: mstoptime      ! model stop time
    character(len=CS)        :: cvalue         ! temporary
    character(len=CS)        :: restart_option ! Restart option units
    integer                  :: restart_n      ! Number until restart interval
    integer                  :: restart_ymd    ! Restart date (YYYYMMDD)
    character(len=CS)        :: stop_option    ! Stop option units
    character(len=CS)        :: glc_avg_period
    integer                  :: stop_n         ! Number until stop interval
    integer                  :: stop_ymd       ! Stop date (YYYYMMDD)
    character(len=CS)        :: hist_option    ! History option units
    integer                  :: hist_n         ! Number until restart interval
    type(ESMF_ALARM)         :: alarm          ! model alarm
    integer                  :: alarmcount
    integer                  :: dtime
    character(len=*),parameter :: subname=trim(modName)//':(ModelSetRunClock) '
    !-------------------------------------------------------------------------------

    rc = ESMF_SUCCESS
    if (dbug > 5) then
       call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO)
    end if

    ! query the Component for its clocks
    call NUOPC_ModelGet(gcomp, driverClock=dclock, modelClock=mclock, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    call ESMF_ClockGet(dclock, currTime=dcurrtime, timeStep=dtimestep, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    call ESMF_ClockGet(mclock, currTime=mcurrtime, timeStep=mtimestep, starttime=mstarttime, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    !--------------------------------
    ! force model clock currtime and timestep to match driver and set stoptime
    !--------------------------------

    mstoptime = mcurrtime + dtimestep
    call ESMF_ClockSet(mclock, currTime=dcurrtime, timeStep=dtimestep, stopTime=mstoptime, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    !--------------------------------
    ! initialize valid input, restart and stop alarms
    !--------------------------------

    call ESMF_ClockGetAlarmList(mclock, alarmlistflag=ESMF_ALARMLIST_ALL, alarmCount=alarmCount, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    if (alarmCount == 0) then

       !----------------
       ! glc valid input alarm
       !----------------
       call NUOPC_CompAttributeGet(gcomp, name="glc_avg_period", value=glc_avg_period, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return

       if (trim(glc_avg_period) == 'hour') then
          call alarmInit(mclock, alarm, 'nhours', opt_n=1, alarmname='alarm_valid_inputs', rc=rc)
          if (ChkErr(rc,__LINE__,u_FILE_u)) return
       else if (trim(glc_avg_period) == 'day') then
          call alarmInit(mclock, alarm, 'ndays' , opt_n=1, alarmname='alarm_valid_inputs', rc=rc)
          if (ChkErr(rc,__LINE__,u_FILE_u)) return
       else if (trim(glc_avg_period) == 'yearly') then
          call alarmInit(mclock, alarm, 'yearly', alarmname='alarm_valid_inputs', rc=rc)
          if (ChkErr(rc,__LINE__,u_FILE_u)) return
       else if (trim(glc_avg_period) == 'glc_coupling_period') then
          call ESMF_TimeIntervalGet(mtimestep, s=dtime, rc=rc)
          if (ChkErr(rc,__LINE__,u_FILE_u)) return
          call alarmInit(mclock, alarm, 'nseconds', opt_n=dtime, alarmname='alarm_valid_inputs', rc=rc)
          if (ChkErr(rc,__LINE__,u_FILE_u)) return
       else
          call ESMF_LogWrite(trim(subname)// ": ERROR glc_avg_period = "//trim(glc_avg_period)//" not supported", &
               ESMF_LOGMSG_INFO, rc=rc)
          rc = ESMF_FAILURE
          RETURN
       end if

       call ESMF_AlarmSet(alarm, clock=mclock, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return

       !----------------
       ! Stop alarm
       !----------------
       call ESMF_LogWrite(subname//'setting stop alarm for cism' , ESMF_LOGMSG_INFO)
       call NUOPC_CompAttributeGet(gcomp, name="stop_option", value=stop_option, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return

       call NUOPC_CompAttributeGet(gcomp, name="stop_n", value=cvalue, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       read(cvalue,*) stop_n

       call NUOPC_CompAttributeGet(gcomp, name="stop_ymd", value=cvalue, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       read(cvalue,*) stop_ymd

       call alarmInit(mclock, alarm, stop_option, opt_n=stop_n, opt_ymd=stop_ymd, &
            RefTime = mcurrTime, alarmname = 'alarm_stop', rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return

       call ESMF_AlarmSet(alarm, clock=mclock, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return

       !----------------
       ! Restart alarm
       !----------------
       call ESMF_LogWrite(subname//'setting restart alarm for cism' , ESMF_LOGMSG_INFO)
       call NUOPC_CompAttributeGet(gcomp, name="restart_option", value=restart_option, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return

       call NUOPC_CompAttributeGet(gcomp, name="restart_n", value=cvalue, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       read(cvalue,*) restart_n

       call NUOPC_CompAttributeGet(gcomp, name="restart_ymd", value=cvalue, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       read(cvalue,*) restart_ymd

       call alarmInit(mclock, alarm, restart_option, opt_n=restart_n,  opt_ymd=restart_ymd, &
            RefTime=mcurrTime, alarmname='alarm_restart', rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return

       call ESMF_AlarmSet(alarm, clock=mclock, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return

       !----------------
       ! History alarm
       !----------------
       call ESMF_LogWrite(subname//'setting history alarm for cism' , ESMF_LOGMSG_INFO)
       call NUOPC_CompAttributeGet(gcomp, name='history_option', value=hist_option, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return

       call NUOPC_CompAttributeGet(gcomp, name='history_n', value=cvalue, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       read(cvalue,*) hist_n

       call alarmInit(mclock, alarm, hist_option, opt_n=hist_n, &
            RefTime = mstartTime, alarmname = 'alarm_history', rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return

    end if

    !--------------------------------
    ! Advance model clock to trigger alarms then reset model clock back to currtime
    !--------------------------------

    call ESMF_LogWrite(subname//'advancing clock for cism' , ESMF_LOGMSG_INFO)
    call ESMF_ClockAdvance(mclock,rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    call ESMF_LogWrite(subname//'setting clock for cism' , ESMF_LOGMSG_INFO)
    call ESMF_ClockSet(mclock, currTime=dcurrtime, timeStep=dtimestep, stopTime=mstoptime, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    if (dbug > 5) then
       call ESMF_LogWrite(subname//' done', ESMF_LOGMSG_INFO)
    end if

  end subroutine ModelSetRunClock

  !===============================================================================

  subroutine ModelFinalize(gcomp, rc)

    ! input/output arguments
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    ! local variables
    character(*), parameter :: F00   = "('(glc_comp_nuopc) ',8a)"
    character(*), parameter :: F91   = "('(glc_comp_nuopc) ',73('-'))"
    character(len=*),parameter  :: subname=trim(modName)//':(ModelFinalize) '
    !-------------------------------------------------------------------------------

    !--------------------------------
    ! Finalize routine
    !--------------------------------

    rc = ESMF_SUCCESS
    if (dbug > 5) then
       call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO)
    end if

    if (my_task==master_task) then
       write(stdout,F91)
       write(stdout,F00) 'CISM: end of main integration loop'
       write(stdout,F91)
    end if

    if (dbug > 5) then
       call ESMF_LogWrite(subname//' done', ESMF_LOGMSG_INFO)
    end if

  end subroutine ModelFinalize

  !===============================================================================

end module glc_comp_nuopc
