import { useState, type ReactNode } from 'react'
import { useOnboardingActions } from './use-onboarding-actions'
import { TourOfferModal } from './tour-offer-modal'
import { CreateFirstVaultModal } from './create-first-vault-modal'
import { ChecklistWidget } from './checklist-widget'
import { DemoVaultProvider, useDemoVault } from './tour/demo-vault-provider'
import { TourController } from './tour/controller'

function ShellInner({ children }: { children: ReactNode }) {
  const ob = useOnboardingActions()
  const demo = useDemoVault()

  const [tourOfferHandled, setTourOfferHandled] = useState(false)
  const [tourActive, setTourActive] = useState(false)
  const [tourReachedEnd, setTourReachedEnd] = useState(false)
  const [vaultModalHandled, setVaultModalHandled] = useState(false)

  if (ob.isLoading) return <>{children}</>

  const isMobile = typeof window !== 'undefined' && window.innerWidth < 768
  const showTourOffer =
    !tourOfferHandled && !ob.hasTourDecision && !isMobile && !tourActive
  const showVaultModal =
    !vaultModalHandled && ob.vaultCount === 0 && !tourActive

  const startTour = async () => {
    ob.record('tour_offered_taken')
    await demo.activate()
    setTourOfferHandled(true)
    setTourActive(true)
  }

  const skipTour = () => {
    ob.record('tour_offered_skipped')
    setTourOfferHandled(true)
  }

  const onTourExit = (reachedEnd: boolean) => {
    if (reachedEnd) ob.record('tour_completed')
    setTourActive(false)
    demo.deactivate()
  }

  return (
    <>
      {children}
      {showTourOffer && (
        <TourOfferModal onTake={startTour} onSkip={skipTour} />
      )}
      {tourActive && (
        <TourController
          active={tourActive}
          reachedEnd={tourReachedEnd}
          setReachedEnd={setTourReachedEnd}
          onExit={onTourExit}
        />
      )}
      {showVaultModal && !showTourOffer && (
        <CreateFirstVaultModal onCreated={() => setVaultModalHandled(true)} />
      )}
      <ChecklistWidget onStartTour={startTour} />
    </>
  )
}

export function OnboardingShell({ children }: { children: ReactNode }) {
  return (
    <DemoVaultProvider>
      <ShellInner>{children}</ShellInner>
    </DemoVaultProvider>
  )
}
