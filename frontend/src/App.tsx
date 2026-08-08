import { AnnouncementBar } from './components/AnnouncementBar'
import { CtaSection } from './components/CtaSection'
import { FeatureGrid } from './components/FeatureGrid'
import { Footer } from './components/Footer'
import { Header } from './components/Header'
import { HeroSection } from './components/HeroSection'
import { MetricsBar } from './components/MetricsBar'
import { MilestoneSection } from './components/MilestoneSection'

function App() {
  return (
    <div className="min-h-screen overflow-hidden">
      <AnnouncementBar />
      <Header />
      <main>
        <HeroSection />
        <MetricsBar />
        <FeatureGrid />
        <MilestoneSection />
        <CtaSection />
      </main>
      <Footer />
    </div>
  )
}

export default App
