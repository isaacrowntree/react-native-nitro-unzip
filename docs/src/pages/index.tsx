import clsx from "clsx";
import Link from "@docusaurus/Link";
import useDocusaurusContext from "@docusaurus/useDocusaurusContext";
import Layout from "@theme/Layout";

import styles from "./index.module.css";

function Hero() {
  const { siteConfig } = useDocusaurusContext();
  return (
    <header className={clsx("hero hero--primary", styles.heroBanner)}>
      <div className="container">
        <h1 className="hero__title">{siteConfig.title}</h1>
        <p className="hero__subtitle">{siteConfig.tagline}</p>
        <div className={styles.buttons}>
          <Link
            className="button button--secondary button--lg"
            to="/docs/getting-started"
          >
            Get Started
          </Link>
        </div>
      </div>
    </header>
  );
}

const features = [
  {
    title: "Blazing Fast",
    description:
      "~500 files/sec on iOS, ~474 files/sec on Android. Powered by SSZipArchive and optimized ZipInputStream with 64KB I/O buffers.",
  },
  {
    title: "Zero Bridge Overhead",
    description:
      "Built on Nitro Modules with JSI. Progress callbacks go directly through the JavaScript Interface — no serialization, no bridge.",
  },
  {
    title: "Cancellable Tasks",
    description:
      "Every operation returns a task object you can cancel synchronously at any time. No waiting for the bridge.",
  },
  {
    title: "Password Support",
    description:
      "Extract and create AES-256 encrypted archives. zip4j on Android, SSZipArchive on iOS.",
  },
  {
    title: "Concurrent Operations",
    description:
      "Run multiple extractions or compressions simultaneously. Each task is an independent, observable instance.",
  },
  {
    title: "Full ZIP Support",
    description:
      "Extract archives, create archives from directories, track progress in real-time, and handle errors gracefully.",
  },
];

function Feature({
  title,
  description,
}: {
  title: string;
  description: string;
}) {
  return (
    <div className={clsx("col col--4")}>
      <div className="padding-horiz--md padding-vert--lg">
        <h3>{title}</h3>
        <p>{description}</p>
      </div>
    </div>
  );
}

function Features() {
  return (
    <section className={styles.features}>
      <div className="container">
        <div className="row">
          {features.map((props, idx) => (
            <Feature key={idx} {...props} />
          ))}
        </div>
      </div>
    </section>
  );
}

function Comparison() {
  return (
    <section className={styles.comparison}>
      <div className="container">
        <h2 className="text--center margin-bottom--lg">
          vs react-native-zip-archive
        </h2>
        <div className={styles.tableWrapper}>
          <table>
            <thead>
              <tr>
                <th></th>
                <th>react-native-nitro-unzip</th>
                <th>react-native-zip-archive</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>Architecture</td>
                <td>JSI (Nitro Modules)</td>
                <td>Bridge</td>
              </tr>
              <tr>
                <td>Progress callbacks</td>
                <td>Via JSI, no serialization</td>
                <td>Via bridge events</td>
              </tr>
              <tr>
                <td>Cancellation</td>
                <td>Synchronous</td>
                <td>Not supported</td>
              </tr>
              <tr>
                <td>Concurrent ops</td>
                <td>Yes</td>
                <td>Limited</td>
              </tr>
              <tr>
                <td>Password support</td>
                <td>AES-256 (zip & unzip)</td>
                <td>Unzip only</td>
              </tr>
              <tr>
                <td>Zip creation</td>
                <td>Yes</td>
                <td>Yes</td>
              </tr>
              <tr>
                <td>New Architecture</td>
                <td>Required</td>
                <td>Optional</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>
  );
}

export default function Home(): React.JSX.Element {
  const { siteConfig } = useDocusaurusContext();
  return (
    <Layout title={siteConfig.title} description={siteConfig.tagline}>
      <Hero />
      <main>
        <Features />
        <Comparison />
      </main>
    </Layout>
  );
}
